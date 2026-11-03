public import CmuxSurfaceCatalogModel
public import Foundation

/// A local pane's failed user-controlled SSH terminal creation request.
public struct TuiPaneCreationFailure: Identifiable, Equatable {
    public let id: UUID
    public let machine: SurfaceMachineID
    public let sourcePanelID: UUID?
    public let title: String
    public let displayTitle: String
    public let errorText: String
    public let recoveryText: String
    /// Captures the real operation error without retaining service/account context.
    /// - Parameters:
    ///   - machine: The SSH machine owning the request.
    ///   - error: The underlying terminal or SSH failure.
    ///   - title: An optional caller-provided card title.
    ///   - recoveryText: An optional caller-provided recovery instruction.
    ///   - sourcePanelID: The pane that initiated the request.
    public init(machine: SurfaceMachineID, error: Error, title: String? = nil, recoveryText: String? = nil, sourcePanelID: UUID? = nil) {
        id = UUID()
        self.machine = machine
        self.sourcePanelID = sourcePanelID
        displayTitle = title ?? String(localized: "sshPane.newTerminalFailed.shortTitle", defaultValue: "Couldn’t open SSH terminal")
        self.title = title ?? displayTitle
        errorText = RemoteMachineLink.errorText(error)
        self.recoveryText = recoveryText ?? String(localized: "sshPane.newTerminalFailed.recovery", defaultValue: "Check the SSH connection, then retry this request.")
    }
    /// The error and recovery text copied from the local card.
    public var copyableText: String { [displayTitle, errorText, recoveryText].joined(separator: "\n") }
}
