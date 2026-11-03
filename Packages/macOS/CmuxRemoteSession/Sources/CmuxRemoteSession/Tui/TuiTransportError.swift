public import Foundation

/// Failures of a native SSH attachment or a revision-fenced terminal mutation.
public enum TuiTransportError: String, Error, LocalizedError, Sendable {
    /// The connection closed before the operation completed.
    case connectionClosed
    /// The acknowledged placement does not match the requested terminal owner.
    case placementMismatch
    /// The remote daemon did not answer within the operation deadline.
    case timedOut
    /// The requested remote terminal no longer exists.
    case terminalNotFound
    /// The remote response violates the attachment protocol.
    case protocolViolation
    /// The installed remote helper lacks a required capability.
    case unsupported
    /// The remote daemon returned a malformed response.
    case invalidResponse
    /// A restored remote owner has no user SSH connection configuration.
    case missingSSHConfiguration
    /// A restored pane has no stable remote terminal identity to attach.
    case missingTerminalIdentity

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: return String(localized: "remote.terminal.connectionClosed", defaultValue: "The SSH terminal connection closed.")
        case .placementMismatch: return String(localized: "remote.terminal.placementMismatch", defaultValue: "The remote terminal placement changed. Reconnect before retrying.")
        case .timedOut: return String(localized: "remote.terminal.timedOut", defaultValue: "The SSH terminal did not respond in time.")
        case .terminalNotFound: return String(localized: "remote.terminal.notFound", defaultValue: "The remote terminal no longer exists.")
        case .protocolViolation, .invalidResponse: return String(localized: "remote.terminal.invalidResponse", defaultValue: "The remote terminal returned an invalid response.")
        case .unsupported: return String(localized: "remote.terminal.unsupported", defaultValue: "Install a compatible cmux-tui on the SSH host, then reconnect.")
        case .missingSSHConfiguration: return String(localized: "remote.terminal.missingSSHConfiguration", defaultValue: "This saved SSH terminal has no connection configuration. Open its SSH host again before restoring the terminal.")
        case .missingTerminalIdentity: return String(localized: "remote.terminal.missingTerminalIdentity", defaultValue: "This saved SSH pane has no remote terminal identity. Open the existing terminal from its SSH host; cmux will not replace it with a local shell.")
        }
    }
}
