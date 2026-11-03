//! Transport-neutral byte streams for the machine-provider protocol.
//!
//! A connector creates one control generation. The generation owns its bearer
//! credential and the factory used to open one fresh byte stream for every
//! provider-issued machine ticket. Protocol framing remains in
//! `machine_provider_client`; this module only owns endpoints and lifetimes.

use std::ffi::{OsStr, OsString};
#[cfg(test)]
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_tui_machine_protocol::BearerToken;
use zeroize::Zeroize;

use crate::process_diagnostics::BoundedDiagnosticBuffer;

const PROVIDER_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const COMMAND_TERMINATION_GRACE: Duration = Duration::from_millis(250);
const COMMAND_DIAGNOSTIC_BYTES: usize = 16 * 1024;

/// Creates a fresh authenticated provider-control generation.
pub(crate) trait MachineProviderConnector: Send + Sync {
    fn connect(&self) -> io::Result<ProviderConnection>;
}

/// Opens one independent byte stream for one provider-issued transport ticket.
pub(crate) trait MachineStreamConnector: Send + Sync {
    fn open(&self) -> io::Result<ProviderIo>;
}

/// One control generation and its associated machine-stream factory.
pub(crate) struct ProviderConnection {
    token: BearerToken,
    control: ProviderIo,
    streams: Arc<dyn MachineStreamConnector>,
}

impl ProviderConnection {
    pub(crate) fn into_parts(self) -> (BearerToken, ProviderIo, Arc<dyn MachineStreamConnector>) {
        (self.token, self.control, self.streams)
    }
}

/// A full-duplex provider endpoint with an explicit shared lifetime guard.
pub(crate) struct ProviderIo {
    reader: Box<dyn Read + Send>,
    writer: Box<dyn Write + Send>,
    guard: ProviderIoGuard,
}

impl ProviderIo {
    fn new<R, W>(reader: R, writer: W, guard: ProviderIoGuard) -> Self
    where
        R: Read + Send + 'static,
        W: Write + Send + 'static,
    {
        Self { reader: Box::new(reader), writer: Box::new(writer), guard }
    }

    pub(crate) fn into_parts(self) -> ProviderIoParts {
        ProviderIoParts { reader: self.reader, writer: self.writer, guard: self.guard }
    }

    #[cfg(test)]
    fn diagnostic(&self) -> Option<String> {
        self.guard.diagnostic()
    }
}

pub(crate) struct ProviderIoParts {
    pub(crate) reader: Box<dyn Read + Send>,
    pub(crate) writer: Box<dyn Write + Send>,
    pub(crate) guard: ProviderIoGuard,
}

trait ProviderIoCleanup: Send + Sync {
    fn close(&self);

    fn add_diagnostic_redaction(&self, _secret: &str) {}

    fn diagnostic(&self) -> Option<String> {
        None
    }
}

/// Clones keep a provider endpoint alive. `close` interrupts every clone.
#[derive(Clone)]
pub(crate) struct ProviderIoGuard {
    cleanup: Arc<dyn ProviderIoCleanup>,
}

impl ProviderIoGuard {
    fn new(cleanup: Arc<dyn ProviderIoCleanup>) -> Self {
        Self { cleanup }
    }

    pub(crate) fn close(&self) {
        self.cleanup.close();
    }

    pub(crate) fn add_diagnostic_redaction(&self, secret: &str) {
        self.cleanup.add_diagnostic_redaction(secret);
    }

    pub(crate) fn diagnostic(&self) -> Option<String> {
        self.cleanup.diagnostic()
    }

    /// Interrupts a blocking pipe or socket read when a handshake stalls.
    pub(crate) fn deadline(&self, timeout: Duration) -> io::Result<ProviderIoDeadline> {
        let cleanup = self.clone();
        let (cancel, cancelled) = mpsc::sync_channel(1);
        let timed_out = Arc::new(AtomicBool::new(false));
        let thread_timed_out = Arc::clone(&timed_out);
        let worker = thread::Builder::new().name("machine-provider-deadline".to_string()).spawn(
            move || {
                if cancelled.recv_timeout(timeout).is_err() {
                    thread_timed_out.store(true, Ordering::Release);
                    cleanup.close();
                }
            },
        )?;
        Ok(ProviderIoDeadline { cancel: Some(cancel), timed_out, worker: Some(worker) })
    }
}

pub(crate) struct ProviderIoDeadline {
    cancel: Option<SyncSender<()>>,
    timed_out: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl ProviderIoDeadline {
    pub(crate) fn timed_out(&self) -> bool {
        self.timed_out.load(Ordering::Acquire)
    }

    fn stop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.try_send(());
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for ProviderIoDeadline {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Existing local Unix-socket provider transport.
pub(crate) struct UnixProviderConnector {
    socket_path: PathBuf,
    token: Option<BearerToken>,
}

impl UnixProviderConnector {
    pub(crate) fn new(socket_path: impl Into<PathBuf>, token: BearerToken) -> Self {
        Self { socket_path: socket_path.into(), token: Some(token) }
    }

    pub(crate) fn generated(socket_path: impl Into<PathBuf>) -> Self {
        Self { socket_path: socket_path.into(), token: None }
    }

    /// Test-only seam for exercising the control socket before `hello`.
    #[cfg(test)]
    pub(crate) fn open_unauthenticated(
        socket_path: impl Into<PathBuf>,
    ) -> io::Result<(ProviderIo, Arc<dyn MachineStreamConnector>)> {
        let streams = Arc::new(UnixMachineStreamConnector { socket_path: socket_path.into() });
        let control = streams.open()?;
        Ok((control, streams))
    }
}

impl MachineProviderConnector for UnixProviderConnector {
    fn connect(&self) -> io::Result<ProviderConnection> {
        let token = match &self.token {
            Some(token) => token.clone(),
            None => random_bearer_token()?,
        };
        let streams =
            Arc::new(UnixMachineStreamConnector { socket_path: self.socket_path.clone() });
        let control = streams.open()?;
        Ok(ProviderConnection { token, control, streams })
    }
}

struct UnixMachineStreamConnector {
    socket_path: PathBuf,
}

impl MachineStreamConnector for UnixMachineStreamConnector {
    fn open(&self) -> io::Result<ProviderIo> {
        let writer = UnixStream::connect(&self.socket_path)?;
        writer.set_write_timeout(Some(PROVIDER_WRITE_TIMEOUT))?;
        let reader = writer.try_clone()?;
        let cleanup =
            Arc::new(UnixCleanup { stream: writer.try_clone()?, closed: AtomicBool::new(false) });
        Ok(ProviderIo::new(reader, writer, ProviderIoGuard::new(cleanup)))
    }
}

struct UnixCleanup {
    stream: UnixStream,
    closed: AtomicBool,
}

impl ProviderIoCleanup for UnixCleanup {
    fn close(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let _ = self.stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

impl Drop for UnixCleanup {
    fn drop(&mut self) {
        self.close();
    }
}

/// Directly executes an arbitrary argv prefix and appends `control` or `stream`.
/// No shell parses the program or its arguments.
pub(crate) struct CommandProviderConnector {
    command: CommandTemplate,
}

impl CommandProviderConnector {
    pub(crate) fn new<I, S>(argv: I) -> io::Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Ok(Self { command: CommandTemplate::new(argv)? })
    }
}

impl MachineProviderConnector for CommandProviderConnector {
    fn connect(&self) -> io::Result<ProviderConnection> {
        let token = random_bearer_token()?;
        let redactions = Arc::new(vec![token.expose().to_string()]);
        let streams =
            Arc::new(CommandMachineStreamConnector { command: self.command.clone(), redactions });
        let control = streams.open_role(CommandRole::Control)?;
        Ok(ProviderConnection { token, control, streams })
    }
}

#[derive(Clone)]
struct CommandMachineStreamConnector {
    command: CommandTemplate,
    redactions: Arc<Vec<String>>,
}

impl CommandMachineStreamConnector {
    fn open_role(&self, role: CommandRole) -> io::Result<ProviderIo> {
        let mut arguments = self.command.arguments.as_ref().clone();
        arguments.push(OsString::from(role.as_str()));
        spawn_command(&self.command.program, &arguments, Arc::clone(&self.redactions))
    }
}

impl MachineStreamConnector for CommandMachineStreamConnector {
    fn open(&self) -> io::Result<ProviderIo> {
        self.open_role(CommandRole::Stream)
    }
}

#[derive(Clone)]
struct CommandTemplate {
    program: OsString,
    arguments: Arc<Vec<OsString>>,
}

impl CommandTemplate {
    fn new<I, S>(argv: I) -> io::Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let mut argv = argv.into_iter().map(Into::into);
        let program = argv.next().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "provider command is empty")
        })?;
        if program.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "provider command program is empty",
            ));
        }
        Ok(Self { program, arguments: Arc::new(argv.collect()) })
    }
}

#[derive(Clone, Copy)]
enum CommandRole {
    Control,
    Stream,
}

impl CommandRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Control => "control",
            Self::Stream => "stream",
        }
    }
}

fn spawn_command(
    program: &OsStr,
    arguments: &[OsString],
    redactions: Arc<Vec<String>>,
) -> io::Result<ProviderIo> {
    let (stderr_cancel, stderr_cancel_worker) = UnixStream::pair()?;
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_remove("CMUX_MACHINE_PROVIDER_TOKEN")
        .env_remove("CMUX_PROVIDER_WORKSPACE_AUTHORITY")
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| {
        io::Error::new(error.kind(), format!("failed to start machine-provider command: {error}"))
    })?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stderr"))?;
    let process_group = match libc::pid_t::try_from(child.id()) {
        Ok(process_group) => process_group,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::other("provider process ID is invalid"));
        }
    };

    let diagnostics =
        Arc::new(BoundedDiagnosticBuffer::with_redactions(COMMAND_DIAGNOSTIC_BYTES, &redactions));
    let cleanup = Arc::new(ProcessCleanup {
        process_group,
        child: Mutex::new(Some(child)),
        diagnostics: Arc::clone(&diagnostics),
        stderr_cancel,
        stderr_worker: Mutex::new(None),
        closed: AtomicBool::new(false),
    });
    let worker_diagnostics = Arc::clone(&diagnostics);
    let worker = thread::Builder::new()
        .name("machine-provider-stderr".to_string())
        .spawn(move || worker_diagnostics.drain_cancellable(stderr, stderr_cancel_worker));
    match worker {
        Ok(worker) => {
            *cleanup
                .stderr_worker
                .lock()
                .map_err(|_| io::Error::other("provider stderr state is poisoned"))? = Some(worker);
        }
        Err(error) => {
            cleanup.close();
            return Err(error);
        }
    }

    Ok(ProviderIo::new(stdout, stdin, ProviderIoGuard::new(cleanup)))
}

struct ProcessCleanup {
    process_group: libc::pid_t,
    child: Mutex<Option<Child>>,
    diagnostics: Arc<BoundedDiagnosticBuffer>,
    stderr_cancel: UnixStream,
    stderr_worker: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl ProcessCleanup {
    fn signal_group(&self, signal: libc::c_int) {
        // `spawn_command` creates a dedicated group whose ID is the direct child PID.
        let _ = unsafe { libc::kill(-self.process_group, signal) };
    }

    fn group_is_alive(&self) -> bool {
        let result = unsafe { libc::kill(-self.process_group, 0) };
        result == 0 || io::Error::last_os_error().kind() == io::ErrorKind::PermissionDenied
    }

    fn terminate_and_reap(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let mut child = self.child.lock().ok().and_then(|mut child| child.take());
            self.signal_group(libc::SIGTERM);
            let deadline = Instant::now() + COMMAND_TERMINATION_GRACE;
            while self.group_is_alive() && Instant::now() < deadline {
                if let Some(child) = &mut child {
                    let _ = child.try_wait();
                }
                thread::sleep(Duration::from_millis(10));
            }
            if self.group_is_alive() {
                self.signal_group(libc::SIGKILL);
            }
            if let Some(mut child) = child {
                let _ = child.wait();
            }
        }
        let _ = self.stderr_cancel.shutdown(std::net::Shutdown::Both);
        if let Ok(mut worker) = self.stderr_worker.lock()
            && let Some(worker) = worker.take()
        {
            let _ = worker.join();
        }
    }
}

impl ProviderIoCleanup for ProcessCleanup {
    fn close(&self) {
        self.terminate_and_reap();
    }

    fn add_diagnostic_redaction(&self, secret: &str) {
        self.diagnostics.add_redaction(secret);
    }

    fn diagnostic(&self) -> Option<String> {
        self.diagnostics.sanitized()
    }
}

impl Drop for ProcessCleanup {
    fn drop(&mut self) {
        self.terminate_and_reap();
    }
}

fn random_bearer_token() -> io::Result<BearerToken> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|_| io::Error::other("cryptographic randomness is unavailable"))?;
    let encoded = URL_SAFE_NO_PAD.encode(bytes);
    bytes.zeroize();
    BearerToken::new(encoded).map_err(|_| io::Error::other("generated bearer token was invalid"))
}





#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    use super::*;

    static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(1);

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new() -> Self {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            // Darwin limits Unix-domain socket paths to 103 bytes. macOS's
            // per-user temporary directory can consume most of that budget.
            let base = if cfg!(target_os = "macos") {
                Path::new("/tmp").to_path_buf()
            } else {
                std::env::temp_dir()
            };
            let path = base.join(format!("cmux-pt-{}-{sequence}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir(&path).expect("create transport test directory");
            Self { path }
        }

        fn script(&self, name: &str, body: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n"))
                .expect("write provider test script");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .expect("make provider test script executable");
            path
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn wait_for_nonempty_file(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while fs::metadata(path).map_or(true, |metadata| metadata.len() == 0) {
            assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_for_file(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !path.exists() {
            assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn command_connector_executes_literal_argv_without_a_shell_or_token_leak() {
        let directory = TestDirectory::new();
        let arguments = directory.path.join("arguments");
        let environment = directory.path.join("environment");
        let complete = directory.path.join("complete");
        let injected = directory.path.join("injected");
        let script = directory.script(
            "record",
            "arguments=$1; environment=$2; complete=$3; shift 3; printf '%s\\n' \"$@\" > \"$arguments.tmp\"; mv \"$arguments.tmp\" \"$arguments\"; env > \"$environment.tmp\"; mv \"$environment.tmp\" \"$environment\"; printf 'done\\n' > \"$complete\"; while IFS= read -r _line; do :; done",
        );
        let metacharacters =
            format!("$(touch {}) ; touch {}", injected.display(), injected.display());
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            arguments.clone().into_os_string(),
            environment.clone().into_os_string(),
            complete.clone().into_os_string(),
            OsString::from(&metacharacters),
        ])
        .expect("create command connector");

        let connection = connector.connect().expect("open command control");
        let (token, control, _) = connection.into_parts();
        wait_for_file(&complete);
        let recorded_arguments = fs::read_to_string(arguments).expect("read recorded arguments");
        let recorded_environment = fs::read_to_string(environment).expect("read environment");
        assert!(recorded_arguments.lines().any(|argument| argument == metacharacters));
        assert_eq!(recorded_arguments.lines().last(), Some("control"));
        assert!(!injected.exists(), "metacharacters were evaluated by a shell");
        assert!(!recorded_arguments.contains(token.expose()));
        assert!(!recorded_environment.contains(token.expose()));
        drop(control);
    }

    #[test]
    fn command_connector_does_not_inherit_provider_capability_secrets() {
        const CHILD_MARKER: &str = "CMUX_PROVIDER_ENV_TEST_CHILD";
        if std::env::var_os(CHILD_MARKER).is_some() {
            let directory = TestDirectory::new();
            let environment = directory.path.join("environment");
            let complete = directory.path.join("complete");
            let script = directory.script(
                "record-environment",
                "environment=$1; complete=$2; env > \"$environment.tmp\"; mv \"$environment.tmp\" \"$environment\"; printf 'done\\n' > \"$complete\"; while IFS= read -r _line; do :; done",
            );
            let connector = CommandProviderConnector::new([
                script.into_os_string(),
                environment.clone().into_os_string(),
                complete.clone().into_os_string(),
            ])
            .expect("create command connector");
            let connection = connector.connect().expect("open command control");
            let (_, control, _) = connection.into_parts();
            wait_for_file(&complete);
            let recorded_environment = fs::read_to_string(environment).expect("read environment");
            assert!(
                !recorded_environment
                    .lines()
                    .any(|line| line.starts_with("CMUX_MACHINE_PROVIDER_TOKEN=")),
                "machine provider token reached child environment"
            );
            assert!(
                !recorded_environment
                    .lines()
                    .any(|line| line.starts_with("CMUX_PROVIDER_WORKSPACE_AUTHORITY=")),
                "provider workspace authority reached child environment"
            );
            drop(control);
            return;
        }

        let helper_test = format!(
            "{}::command_connector_does_not_inherit_provider_capability_secrets",
            module_path!()
        );
        let output =
            Command::new(std::env::current_exe().expect("locate provider environment test binary"))
                .arg("--exact")
                .arg(&helper_test)
                .arg("--nocapture")
                .env(CHILD_MARKER, "1")
                .env("CMUX_MACHINE_PROVIDER_TOKEN", "provider-token-test")
                .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-authority-test")
                .output()
                .expect("run provider environment test helper");
        assert!(
            output.status.success(),
            "provider environment test helper failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn command_connector_uses_fresh_bearers_and_processes_for_every_descriptor() {
        let directory = TestDirectory::new();
        let records = directory.path.join("records");
        let script = directory.script(
            "record-process",
            "records=$1; shift; printf '%s:%s\\n' \"$$\" \"$1\" >> \"$records\"; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            records.clone().into_os_string(),
        ])
        .expect("create command connector");

        let first = connector.connect().expect("open first generation");
        let (first_token, first_control, first_streams) = first.into_parts();
        let first_stream = first_streams.open().expect("open first stream");
        let second_stream = first_streams.open().expect("open second stream");
        let second = connector.connect().expect("open second generation");
        let (second_token, second_control, _) = second.into_parts();
        assert_ne!(first_token.expose(), second_token.expose());
        assert!(first_token.expose().len() >= 32);

        let deadline = Instant::now() + Duration::from_secs(10);
        let lines = loop {
            let lines = fs::read_to_string(&records).unwrap_or_default();
            if lines.lines().count() >= 4 {
                break lines;
            }
            assert!(Instant::now() < deadline, "timed out waiting for command records");
            thread::sleep(Duration::from_millis(10));
        };
        let mut process_ids = lines
            .lines()
            .map(|line| line.split_once(':').expect("pid and role"))
            .collect::<Vec<_>>();
        process_ids.sort_unstable();
        process_ids.dedup();
        assert_eq!(process_ids.len(), 4, "each descriptor must own a distinct process");
        assert_eq!(lines.lines().filter(|line| line.ends_with(":control")).count(), 2);
        assert_eq!(lines.lines().filter(|line| line.ends_with(":stream")).count(), 2);
        drop((first_stream, second_stream, first_control, second_control));
    }

    #[test]
    fn dropping_command_io_kills_and_reaps_its_child() {
        let directory = TestDirectory::new();
        let pid_path = directory.path.join("pid");
        let script = directory.script(
            "block",
            "pid_path=$1; shift; printf '%s' \"$$\" > \"$pid_path\"; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            pid_path.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (_, control, _) = connection.into_parts();
        wait_for_nonempty_file(&pid_path);
        let pid = fs::read_to_string(&pid_path)
            .expect("read child pid")
            .parse::<i32>()
            .expect("parse child pid");
        drop(control);

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let alive = unsafe { libc::kill(pid, 0) } == 0;
            if !alive {
                break;
            }
            assert!(Instant::now() < deadline, "provider child {pid} survived cleanup");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn dropping_command_io_terminates_background_descendants_without_blocking() {
        let directory = TestDirectory::new();
        let descendant_path = directory.path.join("descendant-pid");
        let script = directory.script(
            "background-descendant",
            "descendant_path=$1; shift; sleep 300 & descendant=$!; printf '%s' \"$descendant\" > \"$descendant_path\"; exit 0",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            descendant_path.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (_, control, _) = connection.into_parts();
        wait_for_nonempty_file(&descendant_path);
        let descendant = fs::read_to_string(&descendant_path)
            .expect("read descendant pid")
            .parse::<i32>()
            .expect("parse descendant pid");
        assert_eq!(unsafe { libc::kill(descendant, 0) }, 0, "provider descendant must be alive");

        let (finished_tx, finished_rx) = mpsc::sync_channel(1);
        let cleanup = thread::spawn(move || {
            drop(control);
            let _ = finished_tx.send(());
        });
        let completed = finished_rx.recv_timeout(Duration::from_secs(2)).is_ok();
        if !completed {
            let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
            finished_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("cleanup finishes after the leaked descendant is killed");
        }
        cleanup.join().expect("join provider cleanup");

        assert!(completed, "provider cleanup blocked on a descendant-owned diagnostic pipe");
        let deadline = Instant::now() + Duration::from_secs(5);
        while unsafe { libc::kill(descendant, 0) } == 0 {
            assert!(Instant::now() < deadline, "provider descendant {descendant} survived cleanup");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn detached_stderr_holder() {
        let Some(pid_path) = std::env::var_os("CMUX_TEST_DETACHED_STDERR_HOLDER") else {
            return;
        };
        let session = unsafe { libc::setsid() };
        assert!(session > 0, "detach provider test descendant");
        fs::write(pid_path, std::process::id().to_string())
            .expect("record detached descendant pid");
        thread::sleep(Duration::from_secs(300));
    }

    #[test]
    fn dropping_command_io_cancels_diagnostics_from_a_detached_descendant() {
        let directory = TestDirectory::new();
        let descendant_path = directory.path.join("detached-descendant-pid");
        let helper_test = concat!(
            "machine_provider_client::machine_provider_transport::tests::",
            "detached_stderr_holder"
        );
        let script = directory.script(
            "detached-descendant",
            &format!(
                "test_binary=$1; descendant_path=$2; shift 2; \
                 CMUX_TEST_DETACHED_STDERR_HOLDER=\"$descendant_path\" \
                 \"$test_binary\" --exact \"{helper_test}\" --nocapture & \
                 descendant=$!; \
                 while [ ! -s \"$descendant_path\" ]; do \
                   kill -0 \"$descendant\" 2>/dev/null || exit 1; \
                   sleep 1; \
                 done; \
                 exit 0"
            ),
        );
        let test_binary = std::env::current_exe().expect("locate provider test binary");
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            test_binary.into_os_string(),
            descendant_path.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (_, control, _) = connection.into_parts();
        wait_for_nonempty_file(&descendant_path);
        let descendant = fs::read_to_string(&descendant_path)
            .expect("read detached descendant pid")
            .parse::<i32>()
            .expect("parse detached descendant pid");
        assert_eq!(unsafe { libc::kill(descendant, 0) }, 0, "detached descendant must be alive");

        let (finished_tx, finished_rx) = mpsc::sync_channel(1);
        let cleanup = thread::spawn(move || {
            drop(control);
            let _ = finished_tx.send(());
        });
        let completed = finished_rx.recv_timeout(Duration::from_secs(2)).is_ok();
        if !completed {
            let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
            finished_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("cleanup finishes after the detached descendant is killed");
        }
        cleanup.join().expect("join provider cleanup");

        let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
        assert!(completed, "provider cleanup waited for detached descendant diagnostics");
    }

    #[test]
    fn command_stderr_is_drained_bounded_sanitized_and_token_redacted() {
        let directory = TestDirectory::new();
        let ready = directory.path.join("ready");
        let script = directory.script(
            "stderr",
            "ready=$1; shift; IFS= read -r secret; printf '%s\\n' \"$secret\" >&2; printf ready > \"$ready\"; i=0; while [ $i -lt 20000 ]; do printf 'unsafe\\033[31m diagnostic '; i=$((i + 1)); done >&2; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            ready.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (token, mut control, _) = connection.into_parts();
        control
            .writer
            .write_all(format!("{}\n", token.expose()).as_bytes())
            .expect("send token-shaped input");
        control.writer.flush().expect("flush token-shaped input");
        wait_for_nonempty_file(&ready);

        let deadline = Instant::now() + Duration::from_secs(10);
        let diagnostic = loop {
            let diagnostic = control.diagnostic().unwrap_or_default();
            if diagnostic.contains("[truncated]") {
                break diagnostic;
            }
            assert!(Instant::now() < deadline, "timed out draining provider stderr");
            thread::sleep(Duration::from_millis(10));
        };
        assert!(diagnostic.len() <= COMMAND_DIAGNOSTIC_BYTES + 32);
        assert!(!diagnostic.contains('\u{1b}'));
        assert!(!diagnostic.contains(token.expose()));
        drop(control);
    }



    #[test]
    fn unix_connector_preserves_fixed_token_and_opens_distinct_sockets() {
        use std::os::unix::net::UnixListener;

        let directory = TestDirectory::new();
        let socket_path = directory.path.join("provider.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
        let connector = UnixProviderConnector::new(
            socket_path,
            BearerToken::new("fixed-token").expect("fixed token"),
        );
        let connection = connector.connect().expect("connect Unix control");
        let (token, control, streams) = connection.into_parts();
        let (_accepted_control, _) = listener.accept().expect("accept control");
        let stream = streams.open().expect("connect Unix stream");
        let (_accepted_stream, _) = listener.accept().expect("accept stream");
        assert_eq!(token.expose(), "fixed-token");
        drop((stream, control));
    }

    #[test]
    fn generated_unix_connector_uses_a_fresh_client_side_bearer_per_generation() {
        use std::os::unix::net::UnixListener;

        let directory = TestDirectory::new();
        let socket_path = directory.path.join("generated-provider.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
        let connector = UnixProviderConnector::generated(socket_path);

        let first = connector.connect().expect("connect first generation");
        let (_first_socket, _) = listener.accept().expect("accept first generation");
        let second = connector.connect().expect("connect second generation");
        let (_second_socket, _) = listener.accept().expect("accept second generation");
        let (first_token, first_control, _) = first.into_parts();
        let (second_token, second_control, _) = second.into_parts();

        assert_ne!(first_token.expose(), second_token.expose());
        assert!(first_token.expose().len() >= 32);
        assert!(second_token.expose().len() >= 32);
        drop((first_control, second_control));
    }


    #[test]
    fn deadline_interrupts_a_blocked_provider_pipe() {
        let directory = TestDirectory::new();
        let script = directory.script("block-forever", "while IFS= read -r _line; do :; done");
        let connector = CommandProviderConnector::new([script.into_os_string()])
            .expect("create command connector");
        let connection = connector.connect().expect("open command control");
        let (_, control, _) = connection.into_parts();
        let ProviderIoParts { reader, writer: _writer, guard } = control.into_parts();
        let deadline = guard.deadline(Duration::from_millis(25)).expect("start deadline");
        let mut reader = BufReader::new(reader);
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).expect("deadline closes pipe"), 0);
        assert!(deadline.timed_out());
    }
}
