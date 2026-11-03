import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

extension TuiWorkspaceRenameService {
    func bindingReconciliation(
        binding: RemoteWorkspaceBinding,
        machine: SurfaceMachineID,
        state: TuiState,
        observation: TuiStateObservation,
        projections: [SurfaceProjection],
        resources: [SurfaceResource]
    ) -> BindingReconciliation {
        guard let remoteID = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteID.isEmpty else { return .keep }
        guard observation.freshness == .current,
              state.cursor != nil,
              state.document.containsCollection("workspaces") else { return .keep }
        guard !state.workspaceIDs.contains(remoteID) else { return .keep }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resources: resources
        ), target.machine == machine,
        state.workspaceIDs.contains(target.remoteWorkspaceID) else { return .clear }
        return .rebind(machine: target.machine, remoteWorkspaceID: target.remoteWorkspaceID)
    }

    /// Applies one accepted workspace name without scanning other bindings.
    ///
    /// The accepted daemon graph is the one authority for a cloud workspace's
    /// name. The local custom title is its projection: the sidebar row, the
    /// title bar and every other local reader paint that projection, while the
    /// Cloud tree paints the graph directly, so they agree only while this
    /// write is unconditional. The single exception is an unacknowledged local
    /// intent (queued, in flight, or receipted but not yet in the graph): that
    /// is the creation-race window, where a name typed before the remote
    /// identity bound is still on its way to the daemon and an older snapshot
    /// must not clobber it. Provenance alone never protects a title: a
    /// user-owned title that differs from the graph is stale (renamed from the
    /// Cloud tree or another client, or restored from an older manifest) and
    /// follows the graph like any other (#12986).
    @MainActor
    func reconcileRemoteWorkspaceName(
        workspace: Workspace,
        machine: SurfaceMachineID,
        state: TuiState,
        catalog: SurfaceCatalog,
        observation: TuiStateObservation
    ) {
        guard catalog.tuiStates[machine] == state,
              observation.freshness == .current,
              let binding = workspace.remoteWorkspaceBinding,
              binding.machineID == machine.tuiMachineID,
              let id = binding.remoteWorkspaceID,
              let remote = state.lookupIndex.workspace(id: id) else { return }
        let key = TuiRenameCoordinator.Key.workspace(machine: machine, id: id)
        if let pending = catalog.pendingTuiRenameName(for: key), pending != remote.name { return }
        // Equal confirmations preserve user provenance across refresh.
        if workspace.customTitle == remote.name, workspace.effectiveCustomTitleSource == .user { return }
        guard workspace.customTitle != remote.name || workspace.effectiveCustomTitleSource != .remote else { return }
        let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
        _ = manager?.setCustomTitle(tabId: workspace.id, title: remote.name, source: .remote,
                                    propagateToRemoteTmux: false, propagateToRemoteWorkspace: false)
    }

    /// Reconciles only the identities touched by an accepted event. Full snapshots
    /// also repair workspace names; process-title events never rewrite other rows.
    @MainActor
    func reconcileRemoteState(
        machine: SurfaceMachineID,
        state: TuiState,
        catalog: SurfaceCatalog,
        observation: TuiStateObservation,
        affectedResources: Set<SurfaceResourceID>? = nil,
        workspaceNamesChanged: Bool = true
    ) {
        guard machine.tuiMachineID != nil, catalog.tuiStates[machine] == state else { return }
        if workspaceNamesChanged {
            let snapshot = catalog.snapshot
            let resources = snapshot.resources(on: machine)
            let projectionsByWorkspace = Dictionary(
                grouping: snapshot.projections.filter { $0.resource.machine == machine },
                by: \.workspaceID
            )
            for workspace in environment.workspaces() {
                guard let binding = workspace.remoteWorkspaceBinding, binding.machineID == machine.tuiMachineID,
                      binding.remoteWorkspaceID != nil else { continue }
                switch bindingReconciliation(
                    binding: binding,
                    machine: machine,
                    state: state,
                    observation: observation,
                    projections: projectionsByWorkspace[workspace.id] ?? [],
                    resources: resources
                ) {
                case .keep:
                    break
                case .clear:
                    if catalog.tuiWorkspaceCreationCoordinator.isPending(localWorkspaceID: workspace.id) { continue }
                    workspace.remoteWorkspaceBinding = nil
                    continue
                case .rebind(let targetMachine, let targetWorkspaceID):
                    let targetVMID = targetMachine.tuiMachineID ?? binding.machineID
                    workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(
                        machineID: targetVMID,
                        remoteWorkspaceID: targetWorkspaceID
                    )
                }
                reconcileRemoteWorkspaceName(workspace: workspace, machine: machine, state: state,
                                             catalog: catalog, observation: observation)
            }
        }
        for projection in catalog.projections where projection.resource.machine == machine {
            if let affectedResources, !affectedResources.contains(projection.resource) { continue }
            guard let resource = catalog.resources[projection.resource],
                  let workspace = environment.workspace(projection.workspaceID),
                  workspace.panels[projection.panelID] != nil else { continue }
            guard resource.kind == .terminal else { continue }
            if workspace.panelTitles[projection.panelID] != resource.tuiProcessDisplayTitle {
                _ = workspace.updatePanelTitle(panelId: projection.panelID, title: resource.tuiProcessDisplayTitle)
            }
            guard let tabID = remoteTabID(for: projection, resource: resource),
                  let tab = state.lookupIndex.tab(id: tabID) else { continue }
            let key = TuiRenameCoordinator.Key.tab(machine: machine, id: tabID)
            if let pending = catalog.pendingTuiRenameName(for: key), pending != (tab.name ?? "") { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name else { continue }
            if workspace.panelCustomTitles[projection.panelID] == tab.name,
               workspace.panelCustomTitleSources[projection.panelID] == .user { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name
                    || (tab.name != nil && workspace.panelCustomTitleSources[projection.panelID] != .remote) else { continue }
            _ = workspace.setPanelCustomTitle(panelId: projection.panelID, title: tab.name, source: .remote,
                                               propagateToRemoteTmux: false, propagateToRemoteWorkspace: false)
        }
    }
}
