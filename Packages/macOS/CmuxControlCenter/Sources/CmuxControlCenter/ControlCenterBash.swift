public import Foundation
internal import Darwin
internal import Dispatch

public struct ControlCenterBashResult: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let terminationSignal: Int32?
    public let timedOut: Bool
    public let cancelled: Bool
    public let outputTruncated: Bool
    public let durationSeconds: Double
}

public enum ControlCenterBashError: Error, LocalizedError, Sendable {
    case invalidCommand
    case invalidTimeout
    case invalidDirectory
    case invalidEnvironment
    case systemCall(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "Bash command must be nonempty, contain no NUL bytes, and be at most 16 KiB."
        case .invalidTimeout:
            return "Bash timeout must be greater than zero and at most 300 seconds."
        case .invalidDirectory:
            return "Bash working directory must be a local directory URL without NUL bytes."
        case .invalidEnvironment:
            return "Bash environment names must be nonempty without '=' or NUL, and values must not contain NUL."
        case .systemCall(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))."
        }
    }
}

public enum ControlCenterBash {
    public static func run(command: String, directory: URL, timeout: TimeInterval = 60, environment: [String: String]? = nil) async throws -> ControlCenterBashResult {
        try Task.checkCancellation()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.utf8.contains(0), command.utf8.count <= 16 * 1024 else {
            throw ControlCenterBashError.invalidCommand
        }
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw ControlCenterBashError.invalidTimeout
        }
        guard directory.isFileURL, !directory.path.isEmpty, !directory.path.utf8.contains(0) else {
            throw ControlCenterBashError.invalidDirectory
        }
        guard environment?.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) ?? true else {
            throw ControlCenterBashError.invalidEnvironment
        }
        let cancellation = BashCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Blocking POSIX I/O must not occupy a Swift cooperative executor thread.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try execute(command: command, directory: directory, timeout: timeout, environment: environment, cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(command: String, directory: URL, timeout: TimeInterval, environment overrides: [String: String]?, cancellation: BashCancellation) throws -> ControlCenterBashResult {
        let started = ProcessInfo.processInfo.systemUptime
        let output = try BashPipe()
        defer { output.close() }
        let errors = try BashPipe()
        defer { errors.close() }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "Preparing Bash file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "Preparing Bash stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, output.writeDescriptor, STDOUT_FILENO), "Preparing Bash stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, errors.writeDescriptor, STDERR_FILENO), "Preparing Bash stderr")
        try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path), "Preparing Bash working directory")

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "Preparing Bash spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        // pgroup=0 creates the child's own group atomically, before any command can run.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "Isolating Bash process group")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "Setting Bash process group")
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "Setting Bash signal mask")
        sigfillset(&mask)
        sigdelset(&mask, SIGKILL)
        sigdelset(&mask, SIGSTOP)
        try check(posix_spawnattr_setsigdefault(&attributes, &mask), "Resetting Bash signal dispositions")

        var environment = ProcessInfo.processInfo.environment
        if let overrides { environment.merge(overrides) { _, value in value } }
        environment["PWD"] = directory.path
        var arguments = ["/bin/bash", "--noprofile", "--norc", "-c", command].map { strdup($0) } + [nil]
        var variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for argument in arguments { free(argument) }
            for variable in variables { free(variable) }
        }
        if cancellation.isCancelled { throw CancellationError() }
        var pid: pid_t = 0
        let spawnError = arguments.withUnsafeMutableBufferPointer { argv in
            variables.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(spawnError, "Launching Bash or changing its working directory")
        output.closeWriter()
        errors.closeWriter()

        // Leave the shell waitable until the last group signal. Its PID then cannot be
        // reused for an unrelated process group while cleanup is in progress.
        var ownsChild = true
        defer {
            if ownsChild {
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        var stdout = BashCapture(descriptor: output.readDescriptor)
        var stderr = BashCapture(descriptor: errors.readDescriptor)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var shellExited = false
        var timedOut = false
        var cancelled = false
        var killAt: TimeInterval?
        var closeAt: TimeInterval?
        var descriptors = [
            pollfd(fd: output.readDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: errors.readDescriptor, events: Int16(POLLIN), revents: 0)
        ]
        while true {
            if !shellExited {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    if code == ECHILD { ownsChild = false }
                    throw ControlCenterBashError.systemCall(operation: "Observing Bash exit", code: code)
                }
                shellExited = info.si_pid == pid
            }
            let now = ProcessInfo.processInfo.systemUptime
            cancelled = cancellation.isCancelled
            if killAt == nil {
                timedOut = !shellExited && !cancelled && now - started >= timeout
                if shellExited || timedOut || cancelled {
                    kill(-pid, SIGTERM)
                    killAt = now + 0.2
                }
            }
            if let deadline = killAt, now >= deadline, closeAt == nil {
                kill(-pid, SIGKILL)
                closeAt = now + 0.2
            }
            if shellExited, let deadline = closeAt,
               (stdout.eof && stderr.eof || now >= deadline) {
                break
            }
            descriptors[0].fd = stdout.eof ? -1 : output.readDescriptor
            descriptors[1].fd = stderr.eof ? -1 : errors.readDescriptor
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ControlCenterBashError.systemCall(operation: "Reading Bash output", code: errno)
            }
            if descriptors[0].revents != 0 { try stdout.drain(using: &buffer) }
            if descriptors[1].revents != 0 { try stderr.drain(using: &buffer) }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            let code = errno
            if code == ECHILD { ownsChild = false }
            throw ControlCenterBashError.systemCall(operation: "Reaping Bash", code: code)
        }
        ownsChild = false
        let signal = status & 0x7f
        let stdoutText = stdout.text()
        let stderrText = stderr.text()
        return ControlCenterBashResult(
            stdout: stdoutText.value,
            stderr: stderrText.value,
            exitCode: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
            terminationSignal: signal == 0 ? nil : signal,
            timedOut: timedOut,
            cancelled: cancellation.finish(),
            outputTruncated: stdout.truncated || stderr.truncated || stdoutText.truncated || stderrText.truncated,
            durationSeconds: ProcessInfo.processInfo.systemUptime - started
        )
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        guard code == 0 else { throw ControlCenterBashError.systemCall(operation: operation, code: code) }
    }
}

private final class BashCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { if !finished { cancelled = true } }
    }

    func finish() -> Bool {
        lock.withLock {
            finished = true
            return cancelled
        }
    }
}

private final class BashPipe {
    let readDescriptor: Int32
    private(set) var writeDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw ControlCenterBashError.systemCall(operation: "Creating Bash output pipe", code: errno)
        }
        do {
            // Keep file actions correct even if the host started with a closed stdio FD.
            for index in descriptors.indices {
                if descriptors[index] < 3 {
                    let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                    guard replacement >= 0 else {
                        throw ControlCenterBashError.systemCall(operation: "Preparing Bash output pipe", code: errno)
                    }
                    Darwin.close(descriptors[index])
                    descriptors[index] = replacement
                } else if fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) < 0 {
                    throw ControlCenterBashError.systemCall(operation: "Preparing Bash output pipe", code: errno)
                }
            }
            guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
                throw ControlCenterBashError.systemCall(operation: "Preparing Bash output reader", code: errno)
            }
        } catch {
            for descriptor in descriptors { Darwin.close(descriptor) }
            throw error
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    func closeWriter() {
        if writeDescriptor >= 0 {
            Darwin.close(writeDescriptor)
            writeDescriptor = -1
        }
    }

    func close() {
        Darwin.close(readDescriptor)
        closeWriter()
    }
}

private struct BashCapture {
    static let limit = 32 * 1024
    let descriptor: Int32
    var eof = false
    var truncated = false
    private var bytes = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
        bytes.reserveCapacity(Self.limit)
    }

    mutating func drain(using buffer: inout [UInt8]) throws {
        // A continuously writing child must not starve cancellation or the other pipe.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { eof = true; return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                throw ControlCenterBashError.systemCall(operation: "Draining Bash output", code: errno)
            }
            let kept = min(count, Self.limit - bytes.count)
            bytes.append(contentsOf: buffer.prefix(kept))
            if kept < count { truncated = true }
        }
    }

    func text() -> (value: String, truncated: Bool) {
        let value = String(decoding: bytes, as: UTF8.self)
        guard value.utf8.count > Self.limit else { return (value, false) }
        // Invalid UTF-8 replacement characters can expand captured bytes. Keep the
        // serialized text bounded too, without splitting a Unicode scalar.
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: Self.limit)
        while end.samePosition(in: value.unicodeScalars) == nil {
            end = value.utf8.index(before: end)
        }
        return (String(value[..<end]), true)
    }
}
