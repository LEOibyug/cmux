//! Verifies an explicitly installed remote helper without installing or replacing it.

use std::fmt;
use std::process::Stdio;
use std::time::Duration;

use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};

use crate::ssh_args::background_ssh_arguments;

const OUTPUT_LIMIT: usize = 4_096;
const REAP_TIMEOUT: Duration = Duration::from_secs(2);

pub const DISTRIBUTION_VERSION: &str = match option_env!("CMUX_TUI_DISTRIBUTION_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
pub const BUILD_IDENTITY: &str = env!("CMUX_TUI_BUILD_IDENTITY");

/// An explicit SSH destination and the remote executable to verify.
#[derive(Debug, Clone)]
pub struct SshPrerequisiteConfig {
    pub ssh_binary: String,
    pub destination: String,
    pub port: Option<u16>,
    pub extra_args: Vec<String>,
    pub remote_binary: String,
    pub timeout: Duration,
}

impl SshPrerequisiteConfig {
    pub fn defaults(destination: impl Into<String>) -> Self {
        Self {
            ssh_binary: "ssh".into(),
            destination: destination.into(),
            port: None,
            extra_args: Vec::new(),
            remote_binary: "~/.local/bin/cmux-tui".into(),
            timeout: Duration::from_secs(60),
        }
    }

    fn validate(&self) -> Result<(), PrerequisiteError> {
        for (label, value) in [
            ("SSH destination", self.destination.as_str()),
            ("remote binary", self.remote_binary.as_str()),
        ] {
            if value.is_empty()
                || value.starts_with('-')
                || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_./~:@+-".contains(&byte))
            {
                return Err(PrerequisiteError::Configuration(format!("{label} is not shell-safe")));
            }
        }
        if self.timeout.is_zero() {
            return Err(PrerequisiteError::Configuration("SSH prerequisite timeout is zero".into()));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteProbe {
    pub app: String,
    pub version: String,
    #[serde(default)]
    pub distribution_version: Option<String>,
    #[serde(default)]
    pub build_identity: Option<String>,
    pub remote_protocol: u8,
    pub os: String,
    pub arch: String,
}

/// Reads the installed helper's protocol without any remote filesystem mutation.
pub struct SshPrerequisite {
    config: SshPrerequisiteConfig,
}

impl SshPrerequisite {
    pub fn new(config: SshPrerequisiteConfig) -> Result<Self, PrerequisiteError> {
        config.validate()?;
        Ok(Self { config })
    }

    pub async fn require_available(&self) -> Result<RemoteProbe, PrerequisiteError> {
        let mut command = Command::new(&self.config.ssh_binary);
        command.args(background_ssh_arguments(
            self.config.port,
            &self.config.extra_args,
            &self.config.destination,
        ));
        command
            .args([self.config.remote_binary.as_str(), "remote-probe", "--json"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(PrerequisiteError::Io)?;
        let stdout = child.stdout.take().ok_or_else(|| {
            PrerequisiteError::Io(std::io::Error::other("SSH stdout pipe is unavailable"))
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            PrerequisiteError::Io(std::io::Error::other("SSH stderr pipe is unavailable"))
        })?;
        let completion = tokio::time::timeout(self.config.timeout, async {
            tokio::try_join!(
                read_bounded(stdout, "stdout"),
                read_bounded(stderr, "stderr"),
                async { child.wait().await.map_err(PrerequisiteError::Io) },
            )
        })
        .await;
        let (stdout, stderr, status) = match completion {
            Ok(Ok(result)) => result,
            Ok(Err(error)) => {
                terminate_and_reap(&mut child).await;
                return Err(error);
            }
            Err(_) => {
                terminate_and_reap(&mut child).await;
                return Err(PrerequisiteError::Timeout);
            }
        };
        let status = status.code().unwrap_or(255);
        if status != 0 {
            let stderr = String::from_utf8_lossy(&stderr);
            if stderr.to_ascii_lowercase().contains("is not recognized as an internal or external command") {
                return Err(PrerequisiteError::WindowsRequiresWsl);
            }
            if matches!(status, 126 | 127)
                || stderr.contains("not found")
                || stderr.contains("No such file")
            {
                return Err(PrerequisiteError::Missing);
            }
            return Err(PrerequisiteError::Remote {
                status,
                stderr: stderr.trim().replace(['\r', '\0'], ""),
            });
        }
        let probe: RemoteProbe = serde_json::from_slice(&stdout).map_err(PrerequisiteError::ProbeJson)?;
        if probe.app != "cmux-tui" || probe.remote_protocol != REMOTE_PROTOCOL_VERSION {
            return Err(PrerequisiteError::Incompatible {
                version: probe.version,
                protocol: probe.remote_protocol,
            });
        }
        Ok(probe)
    }
}

async fn read_bounded(
    mut reader: impl tokio::io::AsyncRead + Unpin,
    stream: &'static str,
) -> Result<Vec<u8>, PrerequisiteError> {
    let mut output = Vec::with_capacity(OUTPUT_LIMIT);
    let mut buffer = [0_u8; 1_024];
    loop {
        let read = reader.read(&mut buffer).await.map_err(PrerequisiteError::Io)?;
        if read == 0 {
            return Ok(output);
        }
        if output.len() + read > OUTPUT_LIMIT {
            return Err(PrerequisiteError::OutputLimit { stream, limit: OUTPUT_LIMIT });
        }
        output.extend_from_slice(&buffer[..read]);
    }
}

async fn terminate_and_reap(child: &mut Child) {
    let _ = child.start_kill();
    let _ = tokio::time::timeout(REAP_TIMEOUT, child.wait()).await;
}

#[derive(Debug)]
pub enum PrerequisiteError {
    Configuration(String),
    Io(std::io::Error),
    ProbeJson(serde_json::Error),
    Timeout,
    OutputLimit { stream: &'static str, limit: usize },
    Missing,
    Remote { status: i32, stderr: String },
    WindowsRequiresWsl,
    Incompatible { version: String, protocol: u8 },
}

impl fmt::Display for PrerequisiteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) => write!(formatter, "invalid SSH prerequisite: {message}"),
            Self::Io(error) => write!(formatter, "SSH prerequisite failed: {error}"),
            Self::ProbeJson(error) => write!(formatter, "remote probe was invalid: {error}"),
            Self::Timeout => formatter.write_str("SSH prerequisite probe timed out"),
            Self::OutputLimit { stream, limit } => write!(formatter, "SSH probe {stream} exceeded {limit} bytes"),
            Self::Missing => formatter.write_str(
                "cmux-tui is not installed on the remote host; explicitly install a compatible local build at the configured --remote-binary path before connecting",
            ),
            Self::Remote { status, stderr } => write!(formatter, "remote probe exited {status}: {stderr}"),
            Self::WindowsRequiresWsl => formatter.write_str(
                "native Windows cannot host the cmux-tui remote daemon; install the helper in a WSL 2 Linux environment and connect to that environment",
            ),
            Self::Incompatible { version, protocol } => write!(
                formatter,
                "remote cmux-tui {version} uses remote protocol {protocol}, expected {REMOTE_PROTOCOL_VERSION}; explicitly install a compatible local build before connecting",
            ),
        }
    }
}

impl std::error::Error for PrerequisiteError {}

impl PrerequisiteError {
    pub fn is_retryable_carrier_failure(&self) -> bool {
        match self {
            Self::Timeout | Self::Remote { status: 255, .. } => true,
            Self::Io(error) => matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::TimedOut
                    | std::io::ErrorKind::Interrupted
                    | std::io::ErrorKind::WouldBlock
                    | std::io::ErrorKind::UnexpectedEof
            ),
            _ => false,
        }
    }
}
