import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension Workspace {
    /// Writes a native arrangement change of a bound SSH workspace to its host.
    ///
    /// Called from every Bonsplit layout callback. Changes this workspace makes while
    /// applying the machine's own layout are programmatic and are not echoed back.
    func tuiLayoutDidChange() {
        guard !isProgrammaticSplit, !isRemoteTmuxMirror, pendingTuiBrowserPanelIDs.isEmpty,
              let binding = remoteWorkspaceBinding, let remoteWorkspaceID = binding.remoteWorkspaceID else { return }
        guard let machine = SurfaceMachineID(rawValue: binding.machineID) else { return }
        let catalog = SurfaceCatalog.shared
        guard machine.isSSH, catalog.tuiStates[machine] != nil,
              catalog.provider(for: machine) is any SurfaceWorkspaceLayoutSyncing else { return }
        catalog.tuiWorkspaceLayoutSyncCoordinator.layoutDidChange(
            workspaceID: id, machine: machine, remoteWorkspaceID: remoteWorkspaceID, catalog: catalog
        ) { [weak self] in
            self?.tuiLayoutSyncTree(machine: machine, catalog: catalog)
        }
    }

    /// Only daemon tabs participate in the host layout; local port previews and
    /// panes still being created are left out.
    func tuiLayoutSyncTree(machine: SurfaceMachineID, catalog: SurfaceCatalog) -> TuiLayoutSyncTree? {
        // Layout callbacks run repeatedly during a drag. Select this workspace's
        // projections once instead of scanning the catalog once for every panel.
        tuiLayoutSyncTree(projections: catalog.projections.filter {
            $0.workspaceID == id && $0.resource.machine == machine
        }, machine: machine)
    }

    /// The same tree from explicit projections, for callers that already hold them.
    func tuiLayoutSyncTree(projections: [SurfaceProjection], machine: SurfaceMachineID) -> TuiLayoutSyncTree? {
        var remoteTabs: [String: String] = [:]
        for projection in projections where projection.workspaceID == id && projection.resource.machine == machine {
            guard panels[projection.panelID] != nil, let tab = surfaceIdFromPanelId(projection.panelID),
                  let remoteTabID = projection.remoteTabID else { continue }
            remoteTabs[tab.uuid.uuidString] = remoteTabID
        }
        return Self.tuiLayoutSyncTree(bonsplitController.treeSnapshot(), remoteTabs: remoteTabs)
    }

    private static func tuiLayoutSyncTree(_ node: ExternalTreeNode, remoteTabs: [String: String]) -> TuiLayoutSyncTree? {
        switch node {
        case .pane(let pane):
            let tabIDs = pane.tabs.compactMap { remoteTabs[$0.id] }
            guard !tabIDs.isEmpty else { return nil }
            return .leaf(tabIDs: tabIDs, activeTabID: pane.selectedTabId.flatMap { remoteTabs[$0] })
        case .split(let split):
            switch (tuiLayoutSyncTree(split.first, remoteTabs: remoteTabs),
                    tuiLayoutSyncTree(split.second, remoteTabs: remoteTabs)) {
            case let (first?, second?):
                return .split(horizontal: split.orientation == "horizontal", ratio: split.dividerPosition, first: first, second: second)
            case let (only?, nil), let (nil, only?):
                return only
            case (nil, nil):
                return nil
            }
        }
    }
}
