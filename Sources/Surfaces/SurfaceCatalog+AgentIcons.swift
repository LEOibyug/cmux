import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Visits projections once per accepted catalog transaction, independent of
    /// the number of resources in a full snapshot. Missing resources clear icons.
    func syncTuiTerminalTabIcons(on machine: SurfaceMachineID, affected: Set<SurfaceResourceID>? = nil) {
        guard !machine.isLocal else { return }
        for projection in projections where projection.resource.machine == machine {
            if let affected, !affected.contains(projection.resource) { continue }
            syncTuiTerminalTabIcon(projection)
        }
    }

    func syncTuiTerminalTabIcon(_ projection: SurfaceProjection) {
        guard !projection.resource.machine.isLocal, projection.resource.kind == .terminal,
              let workspace = tuiWorkspaceRenameService.environment.workspace(projection.workspaceID),
              workspace.panels[projection.panelID] is TerminalPanel,
              let tabID = workspace.surfaceIdFromPanelId(projection.panelID),
              let tab = workspace.bonsplitController.tab(tabID) else { return }
        let asset = resources[projection.resource]?.terminalAgentIconAssetName
        guard tab.iconAsset != asset else { return }
        workspace.bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }
}
