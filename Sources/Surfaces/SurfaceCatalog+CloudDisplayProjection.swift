import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Registers a Cloud pane and admits its local display membership through
    /// the same placement coordinator used by pane moves and closes.
    func recordTuiProjection(_ projection: SurfaceProjection) {
        let resolved = projection.remoteWorkspaceID == nil
            ? tuiPlacementCoordinator.projectionInCurrentWorkspace(projection)
            : projection
        insertSupersedingLocalPlaceholder(resolved)
        if resolved.resource.kind == .browser,
           let browser = SurfacePaneFactory.browserPanel(panelID: resolved.panelID, in: resolved.workspaceID) {
            tuiBrowserDocumentDidChange(browser)
        }
        // Recording or restoring a daemon tab never replays a remote move; its
        // recorded coordinates are reconciled against the accepted graph.
        guard resolved.isLocalWorkspaceView else { return }
        tuiPlacementCoordinator.projectionDidMove(resolved, catalog: self)
    }

    /// Records a pane this catalog just materialized and syncs its placement.
    func recordMaterializedProjection(_ projection: SurfaceProjection) {
        record(projection)
        replayMaterializedTuiPlacement(projection)
    }

    /// A newly materialized daemon tab syncs its placement once, as it did
    /// before local display membership moved into ``recordTuiProjection``.
    func replayMaterializedTuiPlacement(_ projection: SurfaceProjection) {
        guard !projection.isLocalWorkspaceView else { return }
        tuiPlacementCoordinator.projectionDidMove(projection, catalog: self)
    }
}
