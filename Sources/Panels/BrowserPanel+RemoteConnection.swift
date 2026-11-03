import CmuxRemoteSession
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import OSLog
import WebKit

private let browserRemoteConnectionLog = Logger(subsystem: "dev.cmux", category: "browser-remote-connection")

extension BrowserPanel {
    /// Keeps the browser-owned readiness callback installed while a committed
    /// WebKit document is rebound to a new route on the same SSH host.
    func bindRemoteBrowserNavigation() {
        remoteAccess.automaticallyNavigateRequest { [weak self] request in
            guard let self, !self.isClosingWebViewLifecycle else { return }
            // Readiness callbacks used to enter through `navigate(to:)`, which
            // installs the authenticated proxy before the first WebKit load.
            // Keep that preparation when the request-preserving path is used;
            // otherwise a proxied SSH route can reach WebKit before its
            // profile has the proxy configuration.
            if let model = self.remoteAccess.model,
               model.usesBrowserProxy,
               let url = request.url,
               self.remoteAccess.owns(url) {
                self.prepareRemoteBrowserNavigation()
            }
            _ = self.navigateWithoutInsecureHTTPPrompt(
                request: request,
                recordTypedNavigation: false,
                trustedInternalNavigation: true
            )
        }
    }

    /// Activates an admitted SSH route independently of the SwiftUI host.
    /// Callers validate resource ownership before reaching this boundary.
    func configureRemoteBrowser(model: RemotePortAccessModel, url: URL, resourceID: SurfaceResourceID? = nil,
                               request: URLRequest? = nil) {
        guard !isClosingWebViewLifecycle else { return }
        webView.stopLoading()
        if let machineID = (resourceID ?? remoteAccess.resourceID)?.machine.rawValue ?? remoteBrowserMachineID {
            prepareRemoteBrowserStore(machineID: machineID)
        }
        // A cached model can navigate synchronously. Its machine/profile store
        // must be installed first, including on reconfiguration and duplication.
        remoteAccess.configure(model: model, url: url, resourceID: resourceID, request: request)
        // RemoteBrowserAccessState canonicalizes SSH loopback identities to the
        // stable `localhost:<port>` origin before any WebKit callbacks publish
        // a URL. Seed the chrome from that identity as well.
        showRemoteAddress(remoteAccess.remoteURL ?? url)
        bindRemoteBrowserNavigation()
        model.connect()
    }

    /// Leaving a remote resource for a user-owned external page ends only this
    /// local projection. The `.replaced` reason keeps a navigation from
    /// editing the remote workspace layout while removing stale restore
    /// provenance from this panel.
    func leaveRemoteResourceForLocalNavigation() {
        pendingRemoteRestoreURL = nil
        // An ordinary local browser again: a blank page may focus its address bar.
        opensLinkedContent = false
        if retainsRemoteResourceForDuplication {
            SurfaceCatalog.shared.endProjections(panelID: id, reason: .replaced)
        }
        remoteAccess.leave()
    }

    /// The catalog projection remains authoritative while a remote pane is an
    /// unavailable placeholder and before its provider has configured the
    /// browser. Deliberate external navigation removes that projection first.
    var remoteResourceForDuplication: SurfaceResourceID? {
        if let resource = remoteAccess.resourceID, !resource.machine.isLocal {
            return resource
        }
        let resource = SurfaceCatalog.shared.projectionRecord(forPanel: id)?.resource
        return resource?.machine.isLocal == false ? resource : nil
    }

    var retainsRemoteResourceForDuplication: Bool {
        remoteAccess.model != nil || remoteResourceForDuplication != nil
    }

    var remoteResourceForSession: SurfaceResourceID? {
        guard retainsRemoteResourceForDuplication else { return nil }
        return remoteResourceForDuplication
    }


    /// Restore by stable resource identity before loading any saved address.
    /// A stale/unknown provider leaves an owned placeholder, never a local page.
    func restoreRemoteResource(_ resource: SurfaceResourceID, preferredURL: URL? = nil,
                             activate: Bool = true, automaticRetriesRemaining: Int = 2) {
        pendingRemoteRestoreURL = preferredURL
        let catalog = SurfaceCatalog.shared
        let isGlobalDock = DockSplitStore.liveStore(containingPanel: id)?.scope == .global
        do {
            if !isGlobalDock {
                try catalog.validateOwnership(of: [resource], at: .workspace(id: workspaceId, placement: .tab))
            }
        }
        catch { remoteAccess.showUnavailable(SurfaceTransferRejection.remoteMachineMismatch.message); return }
        remoteAccess.retainResource(resource)
        retainTransferredSurfaceMachine(resource.machine)
        catalog.restore([SurfaceProjectionRecord(panelID: id, resource: resource)], workspaceID: workspaceId)
        guard activate else { return }
        guard let provider = catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider else {
            showRemoteRestoreUnavailable(
                resource,
                message: String(localized: "remote.browser.restoreUnavailable", defaultValue: "This remote browser is unavailable. Reconnect its SSH session to retry."),
                automaticRetriesRemaining: automaticRetriesRemaining
            )
            return
        }
        guard let known = catalog.resources[resource] else {
            // The provider can be registered before its first forwarded-port
            // snapshot. Force that provider's metadata and graph refresh so a
            // restored port is discovered before retrying materialization.
            showRemoteRestoreUnavailable(
                resource,
                provider: provider,
                message: String(localized: "remote.browser.restoreUnavailable", defaultValue: "This remote browser is unavailable. Reconnect its SSH session to retry."),
                automaticRetriesRemaining: automaticRetriesRemaining
            )
            return
        }
        if let loopbackURL = provider.remoteLoopbackBrowserURL(for: known) {
            let restoredURL = remoteRestoreURL(on: loopbackURL)
            let configured = provider.configureBrowser(self, url: restoredURL, resourceID: resource)
            if configured { pendingRemoteRestoreURL = nil }
            return
        }
        if let browserURL = provider.remoteBrowserOriginURL(for: known, restoring: self) {
            let restoredURL = remoteRestoreURL(on: browserURL)
            let configured = provider.configureBrowser(self, url: restoredURL, resourceID: resource)
            if configured { pendingRemoteRestoreURL = nil }
            return
        }
        provider.showPortUnavailable(
            String(localized: "remote.browser.restoreUnavailable", defaultValue: "This remote browser is unavailable. Reconnect its SSH session to retry."),
            resourceID: resource,
            browser: self
        )
    }

    /// Keeps a restored remote pane recoverable while its configured SSH owner
    /// registers the provider and publishes the forwarded-port snapshot.
    private func showRemoteRestoreUnavailable(
        _ resource: SurfaceResourceID,
        provider: CmuxTuiSurfaceProvider? = nil,
        message: String,
        automaticRetriesRemaining: Int
    ) {
        let preferredURL = pendingRemoteRestoreURL
        let recover: @MainActor (UInt64) async -> Void = { [weak self] request in
            guard let self else { return }
            var resolvedProvider = provider
            if resolvedProvider == nil {
                let query = SurfaceCatalogQueryService(catalog: .shared, resolveSSHProvider: { machineID in
                    guard let app = AppDelegate.shared else { return }
                    for window in app.listMainWindowSummaries() {
                        guard let manager = app.tabManagerFor(windowId: window.windowId) else { continue }
                        for workspace in manager.tabs where workspace.usesSSHTui {
                            guard let configuration = workspace.remoteConfiguration else { continue }
                            let connection = SSHTuiConnection(configuration: configuration)
                            guard connection.id == machineID else { continue }
                            do {
                                _ = try app.sshTuiWorkspaceCoordinator.provider(connection: connection)
                            } catch {
                                browserRemoteConnectionLog.error("SSH browser provider unavailable: \(error.localizedDescription, privacy: .private)")
                            }
                            return
                        }
                    }
                })
                resolvedProvider = await query.provider(for: resource.machine) as? CmuxTuiSurfaceProvider
            }
            if let resolvedProvider {
                resolvedProvider.requestPortDiscovery()
                await resolvedProvider.refresh(force: true)
            }
            guard self.remoteAccess.isCurrentUnavailableRetry(request) else { return }
            self.restoreRemoteResource(
                resource,
                preferredURL: preferredURL,
                automaticRetriesRemaining: max(automaticRetriesRemaining - 1, 0)
            )
        }
        // The staged projection resolves on its own once the provider
        // publishes the resource, so a miss here is still loading. The
        // provider's settled port scan or the restore deadline ends it.
        remoteAccess.showRestoring(retry: recover, unavailableMessage: message)
        if automaticRetriesRemaining > 0 { remoteAccess.retryUnavailable() }
    }

    private static func remoteRestoredURL(_ preferred: URL?, on target: URL) -> URL {
        guard let preferred, var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              let saved = URLComponents(url: preferred, resolvingAgainstBaseURL: false) else { return target }
        if !saved.percentEncodedPath.isEmpty { components.percentEncodedPath = saved.percentEncodedPath }
        components.percentEncodedQuery = saved.percentEncodedQuery
        components.percentEncodedFragment = saved.percentEncodedFragment
        return components.url ?? target
    }

    func remoteRestoreURL(on target: URL) -> URL {
        return Self.remoteRestoredURL(
            pendingRemoteRestoreURL ?? currentURLForTabDuplication,
            on: target
        )
    }

    /// The provider whose machine serves `url` at its private address.
    ///
    /// SSH machines all use this Mac's loopback as their private address, so
    /// a loopback URL routes only to the machine that owns this browser.
    func privateAddressRouteProvider(for url: URL) -> CmuxTuiSurfaceProvider? {
        let catalog = SurfaceCatalog.shared
        if RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? ""),
           let owner = privateAddressRouteOwner, !owner.isLocal {
            return catalog.provider(for: owner) as? CmuxTuiSurfaceProvider
        }
        let addresses = catalog.machines.compactMapValues(\.privateAddress)
        let machine = PrivateAddressRouteSelector<SurfaceMachineID>().machine(
            forHost: Self.privateAddressRouteHost(url.host),
            owner: privateAddressRouteOwner,
            addresses: addresses
        )
        return machine.flatMap { catalog.provider(for: $0) as? CmuxTuiSurfaceProvider }
    }

    /// SSH machines advertise `127.0.0.1`, so every loopback spelling
    /// (`localhost`, `::1`, `0.0.0.0`) names that same private address.
    nonisolated static func privateAddressRouteHost(_ host: String?) -> String? {
        guard let host, PrivateNetworkHostPolicy().isLoopback(host: host) else { return host }
        return "127.0.0.1"
    }

    /// Managed SSH workspaces have no workspace-wide browser proxy.
    var owningWorkspaceRoutesThroughSSHTui: Bool {
        AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs
            .first { $0.id == workspaceId }?
            .usesSSHTui ?? false
    }

    /// The SSH service a loopback URL in a managed SSH workspace names, or `nil`
    /// when the URL loads from this Mac as is: a non-loopback page, or this
    /// pane's own forward listener. A listener URL copied from another pane
    /// maps back to the service it forwards.
    func sshLoopbackServiceURL(for url: URL) -> URL? {
        guard PrivateNetworkHostPolicy().isLoopback(host: url.host ?? "") else { return nil }
        if let listenerPort = remoteAccess.model?.localAddress
            .flatMap({ Int($0.split(separator: ":").last ?? "") }),
           url.scheme?.lowercased() == "http",
           url.port == listenerPort { return nil }
        if let serviceURL = privateAddressRouteProvider(for: url)?.sshServiceURL(forForwardListener: url) {
            return serviceURL
        }
        if let remoteURL = remoteAccess.remoteURL,
           remoteAccess.model?.route == .loopback,
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if remoteAccess.isRetiredListener(url) {
                // A forward restart leaves WebKit history and in-flight
                // commits pointing at the retired listener. Resolve only that
                // known stale port against the stable service identity.
                parts.scheme = remoteURL.scheme
                parts.host = remoteURL.host
                parts.port = remoteURL.port
            } else {
                // A different loopback port can be another SSH service. Keep
                // its port while using this machine's private service host.
                parts.scheme = remoteURL.scheme
                parts.host = remoteURL.host
            }
            return parts.url
        }
        return url
    }

    /// The machine this browser belongs to: its current SSH route, or the
    /// machine that owns its workspace.
    private var privateAddressRouteOwner: SurfaceMachineID? {
        if let machine = remoteResourceForDuplication?.machine { return machine }
        if let machineID = remoteBrowserMachineID { return SurfaceMachineID(rawValue: machineID) }
        return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs
            .first { $0.id == workspaceId }?
            .surfaceOwnershipPolicy.remoteMachine
    }

    @discardableResult
    func rebindRemoteRouteIfNeeded(to url: URL) -> Bool {
        guard let provider = privateAddressRouteProvider(for: url) else {
            return false
        }
        // A loopback URL that commits before the navigation delegate can
        // intercept it has already loaded this Mac's service. Reconfigure the
        // SSH route so the browser follows its listener instead of preserving
        // the wrong local document. Same-VM non-loopback redirects can retain
        // their committed document safely.
        if owningWorkspaceRoutesThroughSSHTui,
           let serviceURL = sshLoopbackServiceURL(for: url) {
            return provider.configureBrowser(self, url: serviceURL)
        }
        return provider.configureBrowser(self, url: url, preserveCurrentNavigation: true)
    }

    /// remote panes use their own persistent data store so configuring one VM cannot reroute another.
    func prepareRemoteBrowserStore(machineID: String) {
        let identifier = RemoteBrowserRouting.storeID(panelID: id, profileID: profileID, machineID: machineID)
        guard remoteBrowserStoreIdentity != identifier else { return }
        remoteBrowserMachineID = machineID
        remoteBrowserStoreIdentity = identifier
        remoteBrowserProxyEndpoint = nil
        websiteDataStore = preservesExplicitEphemeralWebsiteDataStore
            ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: identifier)
        // The route may still be connecting. Do not construct its WebView with
        // an unconfigured store: its first network session must own the proxy.
    }

    /// Apply proxy credentials before the first request, with no system-network fallback.
    func prepareRemoteBrowserNavigation() {
        guard let endpoint = remoteAccess.model?.browserProxy,
              let address = remoteAccess.model?.target.host else { return }
        guard endpoint != remoteBrowserProxyEndpoint else { return }
        remoteBrowserProxyEndpoint = endpoint
        websiteDataStore.proxyConfigurations = [RemoteBrowserRouting.configuration(endpoint: endpoint, address: address, remoteNetwork: remoteAccess.model?.usesRemoteNetwork == true)]
        RemoteBrowserRouting.installWebSocketBridge(endpoint: endpoint, address: address, on: webView, remoteNetwork: remoteAccess.model?.usesRemoteNetwork == true)
        if webView.configuration.websiteDataStore !== websiteDataStore {
            replaceWebViewPreservingState(from: webView, websiteDataStore: websiteDataStore,
                                         reason: "remote_browser_route", restoreAfterReplacement: false)
        }
    }


    func preferredURLStringForSessionSnapshot() -> String? {
        if let serviceURL = remoteAccess.sessionURL(currentURL: currentURL) { return serviceURL.absoluteString }
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: webView.url),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}
