import Foundation

/// The local records covered by a read or clear action.
/// A nil surface selects workspace-level records, not every surface in the workspace.
enum NotificationReadTarget: Equatable, Sendable {
    case all
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID?)
}
