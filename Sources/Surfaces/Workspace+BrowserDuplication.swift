import CmuxSurfaceCatalogModel
import Foundation

/// Browser view duplication retains resource provenance before navigation.
extension Workspace {
    @discardableResult
    func duplicateBrowserToRight(
        panelId: UUID,
        focus: Bool = true,
        creationPolicy: BrowserPanelCreationPolicy = .userInitiated
    ) -> BrowserPanel? {
        guard let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId),
              let browser = browserPanel(for: panelId) else { return nil }
        let catalog = SurfaceCatalog.shared
        let keepsTuiRoute = browser.retainsRemoteResourceForDuplication
        let record = keepsTuiRoute
            ? catalog.projectionRecord(forPanel: panelId).flatMap { $0.resource.machine.isLocal ? nil : $0 }
            : nil
        let resource = keepsTuiRoute ? (record?.resource ?? browser.remoteResourceForDuplication) : nil
        guard surfaceOwnershipPolicy.rejection(for: machineOwningSurface(panelId), kind: AppDelegate.shared?.surfaceResourceKind(for: browser)) == nil else { return nil }
        let isCloud = resource?.machine.isLocal == false
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: isCloud ? nil : browser.currentURLForTabDuplication,
            focus: focus,
            preferredProfileID: browser.profileID,
            creationPolicy: creationPolicy,
            chromeVisibility: browser.chromeVisibility,
            bypassRemoteProxy: browser.bypassesRemoteWorkspaceProxyForTabDuplication,
            websiteDataStore: browser.explicitEphemeralWebsiteDataStoreForSibling
        ) else { return nil }
        if let resource, isCloud {
            // Install the identity before the first network request. In particular,
            // an offline restored display never becomes an anonymous local URL.
            newPanel.retainTransferredSurfaceMachine(resource.machine)
            catalog.restore([SurfaceProjectionRecord(panelID: newPanel.id, resource: resource,
                remoteWorkspaceID: record?.remoteWorkspaceID)], workspaceID: id)
            if let model = browser.remoteAccess.model, let url = browser.remoteAccess.remoteURL {
                let configuredURL = browser.remoteRestoreURL(on: url)
                newPanel.configureRemoteBrowser(model: model, url: configuredURL, resourceID: resource)
            } else {
                newPanel.restoreRemoteResource(resource, preferredURL: browser.currentURLForTabDuplication)
            }
        }
        newPanel.setMuted(browser.isMuted)
        syncBrowserAudioMuteStateForPanel(newPanel.id, browserPanel: newPanel)
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
        return newPanel
    }

}
