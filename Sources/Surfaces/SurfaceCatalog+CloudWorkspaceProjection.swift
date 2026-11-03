import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    func reconcileTuiRemoteState(machine: SurfaceMachineID, state: TuiState, observation: TuiStateObservation? = nil) {
        guard tuiStates[machine] == state else { return }
        tuiPlacementCoordinator.reconcileRemoteState(state, catalog: self)
        tuiWorkspaceProjectionCoordinator.request(machine: machine, catalog: self)
        tuiWorkspaceRenameService.reconcileRemoteState(
            machine: machine,
            state: state,
            catalog: self,
            observation: observation ?? tuiStateObservations[machine] ?? .current
        )
    }


    /// Geometry is a projection of the installed graph, just like its catalog rows.
    /// A refresh or event must pass the provider's ordering fence before either
    /// consumer sees it. No network read is permitted at this projection boundary.
    func tuiWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) -> SurfaceProjectionLayout? {
        guard let state = tuiStates[machine], let document = state.snapshotObject() else { return nil }
        return TuiWorkspaceLayoutTranslator.projectionLayout(
            snapshot: document, machine: machine, workspaceID: workspaceID,
            resources: snapshot.resources(on: machine)
        )
    }

    /// Workspace-row actions may outlive the immutable row that launched them.
    /// Resolve its identity again at the last synchronous point before opening,
    /// so a rename, move or close during refresh cannot resurrect captured members.
    /// Arbitrary groups and local workspaces retain their supplied membership.
    func currentTuiWorkspace(_ group: SurfaceResourceGroup) throws -> (group: SurfaceResourceGroup, layout: SurfaceProjectionLayout?)? {
        if let workspaceID = group.remoteWorkspaceID, let machine = group.placements.first?.resource.machine {
            try checkTuiWorkspaceNavigation(machine: machine, workspaceID: workspaceID)
            // A resource can retain its last remote placement while the
            // machine graph has already removed the workspace. Never reopen
            // that stale identity from resource rows alone.
            guard let info = snapshot.machines.first(where: { $0.id == machine }),
                  info.remoteWorkspaces?.contains(where: { $0.id == workspaceID }) == true else {
                return nil
            }
            if let state = tuiStates[machine],
               tuiStateObservations[machine]?.freshness == .current,
               !state.workspaceIDs.contains(workspaceID) {
                return nil
            }
        }
        guard group.representsWorkspace, let workspaceID = group.remoteWorkspaceID,
              let machine = group.placements.first?.resource.machine,
              publishesRemoteWorkspaceGraph(machine),
              group.placements.allSatisfy({ $0.resource.machine == machine }) else { return nil }
        return (
            try remoteWorkspaceGroup(machine: machine, workspaceID: workspaceID),
            tuiWorkspaceLayout(machine: machine, workspaceID: workspaceID)
        )
    }

    /// An SSH workspace row can be re-resolved once its daemon graph is installed.
    private func publishesRemoteWorkspaceGraph(_ machine: SurfaceMachineID) -> Bool {
        if machine.isLocal { return false }
        return tuiStates[machine] != nil
    }

    /// A newly opened/restored pane immediately receives the already accepted
    /// names. Waiting for the next event leaves quiet terminals stale indefinitely.
    func reconcileTuiProjection(_ projection: SurfaceProjection) {
        guard let state = tuiStates[projection.resource.machine],
              tuiStateObservations[state.machine]?.freshness == .current else { return }
        tuiWorkspaceRenameService.reconcileRemoteState(machine: state.machine, state: state, catalog: self, observation: tuiStateObservations[state.machine] ?? .current)
    }
    func beginProjectionMutation(for resources: [SurfaceResourceID]) -> [SurfaceMachineID: UUID] {
        Dictionary(uniqueKeysWithValues: Set(resources.map(\.machine)).filter { !$0.isLocal }.map { machine in
            let token = tuiWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
            (provider(for: machine) as? any SurfaceProjectionMutationObserving)?.beginProjectionMutation(token)
            return (machine, token)
        })
    }

    func endProjectionMutation(_ tokens: [SurfaceMachineID: UUID]) {
        for (machine, token) in tokens {
            tuiWorkspaceProjectionCoordinator.endLocalMutation(token, on: machine, catalog: self)
            (provider(for: machine) as? any SurfaceProjectionMutationObserving)?.endProjectionMutation(token)
        }
    }

    func requestTuiWorkspaceProjection(_ workspaceID: UUID) {
        guard let binding = tuiWorkspaceProjectionCoordinator.environment.bindings()[workspaceID],
              let machine = SurfaceMachineID(rawValue: binding.machineID) else { return }
        tuiWorkspaceProjectionCoordinator.request(machine: machine, catalog: self)
    }

}
