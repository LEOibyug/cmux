import Foundation

/// A final local stop of a native SSH terminal attachment.
enum TuiManualMirrorStopReason: Equatable, Sendable {
    /// The local pane closed or was replaced.
    case paneClosed
    /// The local carrier was explicitly retired while the pane remained open.
    case tuiUnavailable

    var endedPresentation: RemoteTerminalReconnectOverlayPolicy.Presentation? {
        switch self {
        case .paneClosed: return nil
        case .tuiUnavailable:
            return .init(title: String(localized: "remote.terminal.unavailable.title", defaultValue: "SSH session unavailable"),
                         detail: String(localized: "remote.terminal.unavailable.detail", defaultValue: "The terminal connection is offline. Reconnect when you are ready."),
                         showsProgress: false, showsReconnectButton: true)
        }
    }
}
