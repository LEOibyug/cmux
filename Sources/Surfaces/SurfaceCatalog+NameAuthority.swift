import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Captures a read precondition without I/O. It expires on a name change,
    /// projection move, daemon restart, or local restore before a callback returns.
    func tuiAgentNameContext(workspaceID: UUID, panelID: UUID) -> TuiAgentNameContext? {
        guard let projection = projection(forPanel: panelID), projection.workspaceID == workspaceID,
              tuiStateObservations[projection.resource.machine]?.freshness == .current,
              let state = tuiStates[projection.resource.machine] else { return nil }
        return TuiAgentNameContext(projection: projection, state: state)
    }

    /// Bound SSH names reconcile from the accepted daemon graph; nil keeps local title semantics.
    func submitTuiPanelRename(
        workspace: Workspace, panelID: UUID, title: String?, source: Workspace.CustomTitleSource,
        context: TuiAgentNameContext? = nil
    ) -> Bool? {
        guard let projection = projection(forPanel: panelID), projection.workspaceID == workspace.id,
              !projection.resource.machine.isLocal, projection.resource.kind == .terminal else { return nil }
        let machine = projection.resource.machine
        guard let resource = resources[projection.resource],
              let tabID = tuiWorkspaceRenameService.remoteTabID(for: projection, resource: resource) else { return false }
        let name = TuiRemoteRenameName(rawValue: title ?? "").wireValue
        let key = TuiRenameCoordinator.Key.tab(machine: machine, id: tabID)
        let write: Task<Void, Error>
        if source == .auto {
            guard tuiWorkspaceRenameService.admitsTerminalRename(
                workspace: workspace,
                panelID: panelID,
                resource: resource,
                source: .auto,
                catalog: self
            ) else { return false }
            guard !name.isEmpty, let context,
                  context == tuiAgentNameContext(workspaceID: workspace.id, panelID: panelID),
                  tuiRenameCoordinator.pendingName(for: key) == nil,
                  let provider = provider(for: machine) as? any SurfaceAgentNaming else { return false }
            write = tuiRenameCoordinator.enqueue(key: key, pendingName: name) { [weak self] in
                guard let self, self.provider(for: machine) === provider,
                      context == self.tuiAgentNameContext(workspaceID: workspace.id, panelID: panelID)
                else { throw CancellationError() }
                try await provider.renameAgentTab(context: context, name: name)
            }
        } else {
            write = enqueueRemoteTabRename(on: machine, id: tabID, name: name)
        }
        observeTuiNameWrite(write, workspace: workspace, automatic: source == .auto)
        return true
    }

    func submitRemoteWorkspaceRename(
        workspace: Workspace, title: String?, source: Workspace.CustomTitleSource
    ) -> Bool? {
        guard let target = tuiWorkspaceRenameService.remoteTarget(binding: workspace.remoteWorkspaceBinding, projectedResources: [])
            ?? tuiWorkspaceRenameService.inferredRemoteWorkspaceTarget(
                projections: projections.filter { $0.workspaceID == workspace.id }, resources: [], resourcesByID: resources
            ) else { return nil }
        // A bound SSH workspace shares its daemon name; unbound local workspaces
        // retain their local clear semantics.
        guard source == .user else { return false }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            workspace.presentTuiRenameFailure(message:
                String(localized: "tuiTree.error.renameWorkspaceEmptyName", defaultValue: "A workspace name cannot be empty.")
            )
            return false
        }
        // Upgrade legacy projections before admitting the name. No display text
        // participates in either identity resolution or the remote payload.
        if target.machine.tuiMachineID != nil, workspace.remoteWorkspaceBinding?.remoteWorkspaceID != target.remoteWorkspaceID {
            workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(
                machineID: target.machine.rawValue,
                remoteWorkspaceID: target.remoteWorkspaceID
            )
        }
        let write = enqueueRemoteWorkspaceRename(on: target.machine, id: target.remoteWorkspaceID, name: name)
        observeTuiNameWrite(write, workspace: workspace, automatic: false)
        return true
    }

    private func observeTuiNameWrite(_ write: Task<Void, Error>, workspace: Workspace, automatic: Bool) {
        Task { @MainActor [weak workspace] in
            do { try await write.value }
            catch {
                // A superseded automatic result is expected, not a user error.
                if !automatic, !(error is CancellationError) { workspace?.presentTuiRenameFailure(error) }
            }
        }
    }
}
