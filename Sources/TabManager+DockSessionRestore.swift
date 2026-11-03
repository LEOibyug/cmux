import Foundation

extension TabManager {
    /// Restores each workspace's persisted Dock after workspace topology exists.
    ///
    /// Deferred browser panels are passed through without constructing WebKit
    /// until the corresponding Dock pane becomes visible.
    @discardableResult
    func restoreWorkspaceDockSessionSnapshots(
        from snapshot: SessionTabManagerSnapshot,
        excludingStableIdentities: Set<UUID>,
        deferBrowserPanels: Bool = false
    ) -> [UUID: [UUID: UUID]] {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        var restoredPanelIDs: [UUID: [UUID: UUID]] = [:]
        var workspacesByOriginalId: [UUID: Workspace] = [:]
        let identityCounts = pairs.compactMap { $0.snapshot.workspaceId }.reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
        for pair in pairs {
            if let originalId = pair.snapshot.workspaceId, identityCounts[originalId] == 1 {
                workspacesByOriginalId[originalId] = pair.workspace
            }
        }
        for pair in pairs {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            restoredPanelIDs[pair.workspace.id] = pair.workspace.dockSplit?.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { workspacesByOriginalId[$0] }
            )
        }
        return restoredPanelIDs
    }

    func restoredSessionWorkspace(
        originalId: UUID,
        from snapshot: SessionTabManagerSnapshot
    ) -> Workspace? {
        restoredSessionWorkspacePairs(from: snapshot).first {
            $0.snapshot.workspaceId == originalId
        }?.workspace
    }

    private func restoredSessionWorkspacePairs(
        from snapshot: SessionTabManagerSnapshot
    ) -> [(snapshot: SessionWorkspaceSnapshot, workspace: Workspace)] {
        let (normalizedSnapshots, _, _) = Self.normalizedSessionRestoreWorkspaces(
            snapshot.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex
        )
        return Array(zip(
            normalizedSnapshots.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            tabs
        ))
    }
}
