import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Returns the last accepted cwd for a stale Cloud terminal, when its identity still exists.
    ///
    /// A stale graph is useful display state, but a resource row can also contain an optimistic
    /// requested cwd. Read the cached value from the accepted graph so that a request, a retired
    /// provider, or a resource whose identity disappeared cannot become a displayed path.
    private func acceptedStaleTuiDirectory(for resource: SurfaceResource) -> String? {
        guard resource.kind == .terminal,
              resource.machine.tuiMachineID != nil,
              tuiStateObservations[resource.machine]?.freshness == .stale,
              let directory = tuiStates[resource.machine]?.lookupIndex.terminal(id: resource.id.key)?.cwd else {
            return nil
        }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Retain stale graphs for diagnostics while presenting a previously accepted cwd as a
    /// cached value. A requested launch directory or a stale graph with no accepted cwd remains
    /// unavailable.
    func resourceForPresentation(_ resource: SurfaceResource) -> SurfaceResource {
        if resource.kind == .browser { return resourceWithTuiBrowserDocument(resource) }
        // SSH graph freshness determines whether an accepted cwd is current or cached.
        guard resource.kind == .terminal, resource.machine.tuiMachineID != nil else { return resource }
        guard tuiStateObservations[resource.machine]?.freshness != .current else { return resource }
        var result = resource
        result.detail = acceptedStaleTuiDirectory(for: resource)
        return result
    }

    /// Projects accepted directory and machine metadata independently from name reconciliation.
    /// The catalog remains authoritative; Workspace owns only the UI-facing projection.
    func updateTuiDirectoryMetadata(on machine: SurfaceMachineID, affectedResourceIDs: Set<SurfaceResourceID>? = nil) {
        guard !machine.isLocal else { return }
        let machineProjections = projections.filter {
            $0.resource.machine == machine && (affectedResourceIDs?.contains($0.resource) ?? true)
        }
        let projectedWorkspaceIDs = Set(machineProjections.map(\.workspaceID))
        if let affectedResourceIDs {
            // Group the complete projection set once. The workspace updater
            // needs all of a workspace's rows to preserve existing bindings,
            // but an incremental resource update must not rescan and sort the
            // global projection list once per affected workspace.
            let recordsByWorkspace = Dictionary(grouping: projections.filter { !$0.resource.machine.isLocal }) {
                $0.workspaceID
            }.mapValues { projections in
                projections.map {
                    SurfaceProjectionRecord(
                        panelID: $0.panelID,
                        resource: $0.resource,
                        remoteWorkspaceID: $0.remoteWorkspaceID,
                        remoteTabID: $0.remoteTabID
                    )
                }
            }
            for id in projectedWorkspaceIDs {
                guard let workspace = tuiWorkspaceRenameService.environment.workspace(id) else { continue }
                updateTuiDirectoryMetadata(
                    in: workspace,
                    affectedResourceIDs: affectedResourceIDs,
                    projected: recordsByWorkspace[id] ?? []
                )
            }
            return
        }
        for workspace in tuiWorkspaceRenameService.environment.workspaces()
            where (machine.tuiMachineID != nil && workspace.remoteWorkspaceBinding?.machineID == machine.tuiMachineID) || projectedWorkspaceIDs.contains(workspace.id)
                || workspace.remoteBindingState.projectedResources.values.contains(where: { $0.machine == machine }) {
            updateTuiDirectoryMetadata(in: workspace)
        }
    }

    func updateTuiDirectoryMetadata(localWorkspaceID: UUID) {
        guard let workspace = tuiWorkspaceRenameService.environment.workspace(localWorkspaceID) else { return }
        updateTuiDirectoryMetadata(in: workspace)
    }

    private func updateTuiDirectoryMetadata(
        in workspace: Workspace,
        affectedResourceIDs: Set<SurfaceResourceID>? = nil,
        projected suppliedProjections: [SurfaceProjectionRecord]? = nil
    ) {
        // Saved projections establish ownership even before their provider rediscovers the resource.
        let projected = (suppliedProjections ?? projectionRecords(forWorkspace: workspace.id))
            .filter { !$0.resource.machine.isLocal }
        let resourcesByPanel = Dictionary(projected.map { ($0.panelID, $0.resource) }, uniquingKeysWith: { first, _ in first })
        var machineIDs = Set(projected.map { $0.resource.machine.rawValue })
        if let id = workspace.remoteWorkspaceBinding?.machineID { machineIDs.insert(id) }
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            (id, SurfaceMachineID(rawValue: id).flatMap { machines[$0]?.name } ?? id)
        })
        let previous = workspace.remoteBindingState.projectedResources
        let previousHostLabel = workspace.hostLabel
        // The sidebar hides a panel whose terminal row is missing or still launching, so the row's
        // arrival and readiness are presentation inputs even when the projection, names and cwd
        // stay the same. Without them the workspace row stays blank until an unrelated change.
        let terminalLifecycles = Dictionary(projected.compactMap { projection -> (UUID, SurfaceLifecycle)? in
            guard let resource = resources[projection.resource], resource.kind == .terminal else { return nil }
            return (projection.panelID, resource.lifecycle)
        }, uniquingKeysWith: { first, _ in first })
        workspace.remoteBindingState.updateCatalogMetadata(
            resources: resourcesByPanel, machineNames: names, terminalLifecycles: terminalLifecycles
        )
        if workspace.hostLabel != previousHostLabel {
            workspace.owningTabManager?.workspaceHostLabelDidChange(workspace)
        }
        for panelID in previous.keys where resourcesByPanel[panelID] == nil && workspace.panels[panelID] != nil {
            workspace.clearRemotePanelDirectory(panelId: panelID)
        }
        for projection in projected where workspace.panels[projection.panelID] != nil {
            if let affectedResourceIDs, !affectedResourceIDs.contains(projection.resource) { continue }
            let machine = projection.resource.machine
            let resource = resources[projection.resource]
            let current = tuiStateObservations[machine]?.freshness == .current
            let directory: String?
            if let resource, resource.kind == .terminal {
                directory = current
                    ? tuiStates[machine]?.lookupIndex.terminal(id: projection.resource.key)?.cwd
                    : acceptedStaleTuiDirectory(for: resource)
            } else {
                directory = nil
            }
            if let directory, workspace.reportedPanelDirectory(panelId: projection.panelID) == directory { continue }
            workspace.updateTuiPanelDirectory(panelId: projection.panelID, directory: directory)
        }
    }
}
