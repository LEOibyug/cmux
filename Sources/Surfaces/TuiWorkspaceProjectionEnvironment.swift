import CmuxSurfaceCatalogModel
import Foundation

/// Native projection operations supplied by the app, or an isolated test host.
@MainActor
struct TuiWorkspaceProjectionEnvironment {
    var bindings: () -> [UUID: RemoteWorkspaceBinding]
    var close: (SurfaceProjection) -> Void
    var applyLayout: (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void
    var pendingTuiBrowserPanelIDs: (UUID) -> Set<UUID>

    init(
        bindings: @escaping () -> [UUID: RemoteWorkspaceBinding] = { [:] },
        close: @escaping (SurfaceProjection) -> Void = { _ in },
        applyLayout: @escaping (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void = { _, _, _ in },
        pendingTuiBrowserPanelIDs: @escaping (UUID) -> Set<UUID> = { _ in [] }
    ) {
        self.bindings = bindings
        self.close = close
        self.applyLayout = applyLayout
        self.pendingTuiBrowserPanelIDs = pendingTuiBrowserPanelIDs
    }

    init(workspaces: TuiWorkspaceRenameEnvironment) {
        bindings = {
            Dictionary(uniqueKeysWithValues: workspaces.workspaces().compactMap { workspace in
                workspace.remoteWorkspaceBinding.map { (workspace.id, $0) }
            })
        }
        close = { projection in
            SurfacePaneFactory.closeExited(panelID: projection.panelID, in: projection.workspaceID)
        }
        applyLayout = { id, layout, projections in
            workspaces.workspace(id)?.applyTuiWorkspaceLayout(layout, projections: projections)
        }
        pendingTuiBrowserPanelIDs = { id in
            workspaces.workspace(id)?.pendingTuiBrowserPanelIDs ?? []
        }
    }
}
