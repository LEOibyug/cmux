import Foundation

extension TuiWorkspaceRenameService {
    /// Applies accepted cmux-tui terminal cwd values to projected Cloud panels.
    ///
    /// - Parameters:
    ///   - localWorkspaceID: The local workspace whose projected panels are updated.
    ///   - catalog: The authoritative surface catalog containing projections and resources.
    @MainActor
    func updateTuiDirectories(localWorkspaceID: UUID, catalog: SurfaceCatalog) {
        catalog.updateTuiDirectoryMetadata(localWorkspaceID: localWorkspaceID)
    }
}
