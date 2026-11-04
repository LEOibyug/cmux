public import CmuxTui
public import Foundation

/// The one machine-link operation the attachment resolver depends on: run a
/// cmux-tui CLI command against the link socket under a bounded deadline.
///
/// ``RemoteMachineLink`` is the production implementation. Tests conform a
/// scripted runner that answers per argv, so resolver behavior is observable
/// without a client process or a machine.
public protocol TuiCommandRunning: Sendable {
    /// Runs one command and returns its stdout. Throws
    /// ``RemoteMachineLink/LinkError`` for a non-zero exit, a spawn failure, or
    /// the deadline.
    func runTuiCommand(arguments: TuiRequest, deadline: Duration) async throws -> Data
}

/// Sends a Cloud TUI request without waiting for its response.
///
/// Input uses this path because the PTY is the source of truth for echo and
/// line discipline. The request is written on the link's persistent channel;
/// no retry is attempted after the bytes have been handed to that channel.
public protocol TuiUntrackedCommandSending: Sendable {
    nonisolated func sendUntrackedTuiCommand(arguments: TuiRequest) async throws
}

extension RemoteMachineLink: TuiCommandRunning {
    public func runTuiCommand(arguments: TuiRequest, deadline: Duration) async throws -> Data {
        try await run(arguments: arguments, timeout: deadline)
    }
}

extension RemoteMachineLink: TuiUntrackedCommandSending {}
