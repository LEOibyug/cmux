public import Foundation
public import Observation

/// The one observable fact a native cloud pane needs about its attachment.
///
/// Owned by ``TuiManualMirrorSession`` and handed to the pane's panel by
/// reference, so the pane can show a reconnecting state without reaching into
/// the session. Only the session writes it.
@MainActor
@Observable
public final class RemoteTerminalAttachmentStatus {
    public let machineID: String
    public private(set) var state: RemoteTerminalAttachmentState = .attaching(attempt: 1)
    /// One-shot style hook for owners that are not SwiftUI views (the workspace
    /// clearing an optimistic pane's tab spinner). Set by the pane owner only.
    @ObservationIgnored public var onStateChange: (@MainActor (RemoteTerminalAttachmentState) -> Void)?

    public init(machineID: String) {
        self.machineID = machineID
    }

    public func update(_ state: RemoteTerminalAttachmentState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }
}
