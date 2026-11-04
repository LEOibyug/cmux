import CmuxSurfaceCatalogModel
import Foundation

/// A local workspace bound to a machine, as the placement resolver sees it.
struct TuiNotificationBoundWorkspace: Equatable, Sendable {
    init(
        workspaceID: UUID,
        remoteWorkspaceID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    let workspaceID: UUID
    let remoteWorkspaceID: String?
}
