import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog: TuiTerminalNavigationCatalog {
    func localWorkspaceShowing(remoteWorkspaceID: String, placements: [SurfaceResourcePlacement]) -> UUID? {
        let members = Set(placements)
        var counts: [UUID: Int] = [:]
        for projection in projections where projection.remoteWorkspaceID == remoteWorkspaceID {
            let placement = SurfaceResourcePlacement(resource: projection.resource,
                remoteWorkspaceID: projection.remoteWorkspaceID, remoteTabID: projection.remoteTabID)
            if members.contains(placement) { counts[projection.workspaceID, default: 0] += 1 }
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.uuidString > rhs.key.uuidString : lhs.value < rhs.value
        }?.key
    }

    func projectTerminal(_ resource: SurfaceResourceID, in workspaceID: UUID, view: SurfaceRemoteView?) async throws -> SurfaceProjection {
        let opened: (projection: SurfaceProjection, reused: Bool)
        if let view {
            opened = try await project(
                resource, into: .workspace(id: workspaceID, placement: .tab),
                focus: true, reuseExisting: true, reuseInWorkspace: workspaceID, remoteView: view
            )
        } else {
            opened = try await project(
                resource, into: .workspace(id: workspaceID, placement: .tab),
                focus: true, reuseExisting: true, reuseInWorkspace: workspaceID
            )
        }
        return opened.projection
    }

    func terminalWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) async -> SurfaceProjectionLayout? {
        await TuiWorkspaceLayoutTranslator.fetch(machine: machine, workspaceID: workspaceID, catalog: self)
    }

    func openTerminalWorkspace(_ group: SurfaceResourceGroup, title: String, layout: SurfaceProjectionLayout?) async throws
        -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        try await projectGroupAsNewLocalWorkspace(group, title: title, focus: true, host: .appOptimistic, layout: layout)
    }

    func bindTerminalWorkspace(localWorkspaceID: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String, generatedTitle: String) {
        bindRemoteWorkspace(
            localWorkspaceID: localWorkspaceID, machine: machine, remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: generatedTitle
        )
    }
}
