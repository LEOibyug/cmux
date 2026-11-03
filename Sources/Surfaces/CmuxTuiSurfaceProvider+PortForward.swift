import CmuxRemoteSession
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Rebind active browser panes when the VM private address changes.
    func refreshTuiBrowserRoutes() {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID) else { continue }
                if let loopbackURL = remoteLoopbackBrowserURL(for: resource) {
                    let configured = configureBrowser(browser, url: browser.remoteRestoreURL(on: loopbackURL), resourceID: resource.id)
                    if configured { browser.pendingRemoteRestoreURL = nil }
                    continue
                }
                if let browserURL = remoteBrowserOriginURL(for: resource, restoring: browser) {
                    let configured = configureBrowser(browser, url: browser.remoteRestoreURL(on: browserURL), resourceID: resource.id)
                    if configured { browser.pendingRemoteRestoreURL = nil }
                    continue
                }
                switch TuiPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    if let url = URL(string: raw) {
                        let configured = configureBrowser(browser, url: browser.remoteRestoreURL(on: url), resourceID: resource.id)
                        if configured { browser.pendingRemoteRestoreURL = nil }
                    }
                case .unsupported(let message):
                    showPortUnavailable(message, resourceID: resource.id, browser: browser)
                }
            }
        }
    }

    /// Create the browser with native connection state before attempting access.
    /// The authenticated userspace proxy keeps each VM's address and port.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool,
        reusing existingPane: (workspaceID: UUID, panelID: UUID)? = nil
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        try Task.checkCancellation()
        try catalog.validateOwnership(of: [resource.id], at: destination)
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let pane = try existingPane
            ?? SurfacePaneFactory.makeTuiResourceBrowserPane(at: destination, focus: focus)
        guard let browser = SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID) else {
            throw ProviderError.localForwardURLUnavailable
        }
        if let loopbackURL = remoteLoopbackBrowserURL(for: resource) {
            let configured = configureBrowser(browser, url: loopbackURL, resourceID: resource.id)
            guard configured else { throw ProviderError.localForwardURLUnavailable }
            return pane
        }
        if let browserURL = remoteBrowserOriginURL(for: resource, restoring: browser) {
            let configured = configureBrowser(browser, url: browserURL, resourceID: resource.id)
            guard configured else { throw ProviderError.localForwardURLUnavailable }
            return pane
        }
        switch TuiPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let raw):
            guard let url = URL(string: raw) else { throw ProviderError.localForwardURLUnavailable }
            configureBrowser(browser, url: url, resourceID: resource.id)
        case .unsupported(let message):
            showPortUnavailable(message, resourceID: resource.id, browser: browser)
        }
        return pane
    }

    /// Bind the page to its machine proxy without activating a system VPN.
    @discardableResult
    func configureBrowser(_ browser: BrowserPanel, url: URL, resourceID: SurfaceResourceID? = nil,
                          preserveCurrentNavigation: Bool = false, request: URLRequest? = nil) -> Bool {
        if url == SurfacePaneFactory.blankURL, let resourceID,
           resourceID.machine == machine, machine.tuiMachineID != nil,
           let resource = catalog.resources[resourceID], resource.kind == .browser,
           !resourceID.isForwardedPort, resource.remoteViews?.isEmpty == false {
            guard isRegisteredInCatalog(),
                  browser.remoteAccess.resourceID?.machine == nil || browser.remoteAccess.resourceID?.machine == machine,
                  (try? catalog.validateOwnership(of: [resourceID], at: .workspace(id: browser.workspaceId, placement: .tab))) != nil else { return false }
            browser.remoteAccess.leave()
            browser.remoteAccess.retainResource(resourceID)
            browser.retainTransferredSurfaceMachine(machine)
            browser.prepareRemoteBrowserStore(machineID: machineID)
            browser.webView.stopLoading()
            browser.shouldRenderWebView = false
            browser.showRemoteAddress(url)
            materializedPanels.insert(browser.id)
            return true
        }
        let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let fallbackID = SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(requestedPort)")
        let projectedResource = catalog.projectionRecord(forPanel: browser.id).flatMap {
            $0.resource.machine.isLocal ? nil : $0.resource
        }
        let retainedResource = browser.remoteAccess.resourceID ?? projectedResource
        let explicitResource: SurfaceResourceID?
        if let resourceID {
            explicitResource = resourceID
        } else if let retainedResource,
                  Self.port(for: retainedResource, catalog: catalog) == nil
                    || Self.port(for: retainedResource, catalog: catalog) == requestedPort {
            explicitResource = retainedResource
        } else {
            // A URL that changes the service port must resolve to the requested
            // catalog slot instead of carrying the old display identity forward.
            explicitResource = nil
        }
        if let explicitResource,
           let expectedPort = Self.port(for: explicitResource, catalog: catalog),
           expectedPort != requestedPort {
            browser.remoteAccess.showUnavailable(String(localized: "ssh.browser.portMismatch", defaultValue: "This browser route no longer matches the requested SSH port. Reopen the port from its host."))
            return false
        }
        let resourceID = explicitResource ?? fallbackID
        let isGlobalDock = DockSplitStore.liveStore(containingPanel: browser.id)?.scope == .global
        let destinationOwned = isGlobalDock
            || (try? catalog.validateOwnership(of: [resourceID], at: .workspace(id: browser.workspaceId, placement: .tab))) != nil
        guard resourceID.machine == machine,
              browser.remoteAccess.resourceID?.machine == nil || browser.remoteAccess.resourceID?.machine == machine,
              destinationOwned else {
            browser.remoteAccess.showUnavailable(SurfaceTransferRejection.remoteMachineMismatch.message)
            return false
        }
        let isTuiLoopback = machine.tuiMachineID != nil
            && RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? "")
        let isTuiBrowserOrigin = machine.tuiMachineID != nil
            && resourceID.kind == .browser
            && catalog.resources[resourceID]?.remoteViews?.isEmpty == false
            && !isTuiLoopback
        let address = if isTuiLoopback {
            RemoteLoopbackProxyAlias.aliasHost
        } else if isTuiBrowserOrigin {
            url.host
        } else {
            info.privateAddress
        }
        let isHTTPSLoopback = isTuiLoopback && url.scheme?.lowercased() == "https"
        let route: RemotePortAccessRoute = isTuiLoopback || isTuiBrowserOrigin ? .remoteBrowser : .browserProxy
        let routedURL: URL?
        if isTuiLoopback {
            routedURL = url
        } else if isTuiBrowserOrigin {
            let validScheme = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            routedURL = validScheme && url.host?.isEmpty == false ? url : nil
        } else {
            routedURL = address.flatMap {
                RemotePortRoutePolicy().privateURL(
                    url.absoluteString,
                    address: $0,
                    allowLoopback: machine.isSSH || isTuiLoopback
                )
            }
        }
        guard let address, let privateURL = routedURL else {
            browser.remoteAccess.showUnavailable(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            return false
        }
        if machine.isSSH, privateURL.scheme?.lowercased() == "https" {
            browser.remoteAccess.showUnavailable(String(localized: "ssh.tui.browserForward.httpsUnsupported", defaultValue: "HTTPS services on an SSH host can't open in the browser yet. Use http:// instead."))
            return false
        }
        // Check the VM origin before rewriting it to localhost. Otherwise the
        // implicit localhost allowance could bypass a private-origin deny rule.
        guard browserPolicy().allowsTrustedInternalURL(privateURL) else {
            browser.remoteAccess.showUnavailable(String(localized: "browser.error.urlAllowlist.userMessage", defaultValue: "This URL is not allowed by the embedded-browser URL policy."))
            return false
        }
        if let existing = catalog.projectionRecord(forPanel: browser.id), existing.resource != resourceID {
            catalog.endProjections(panelID: browser.id, reason: .replaced)
            catalog.restore([SurfaceProjectionRecord(panelID: browser.id, resource: resourceID)], workspaceID: browser.workspaceId)
        }
        let port = privateURL.port ?? (privateURL.scheme?.lowercased() == "https" ? 443 : 80)
        let model = accessModel(
            port: port,
            address: address,
            targetHost: isTuiBrowserOrigin ? url.host : address,
            scheme: privateURL.scheme ?? "http",
            route: route,
            preservesRemoteHost: isTuiLoopback || isHTTPSLoopback || isTuiBrowserOrigin
        )
        browser.retainTransferredSurfaceMachine(machine)
        // Keep the URL the user opened as the browser's logical service
        // identity. SSH still uses `privateURL` for policy validation and the
        // access model's target, but the loopback listener is only a transport
        // detail and must not replace `localhost:<port>` in the address bar.
        let logicalURL = machine.isSSH ? url : privateURL
        if preserveCurrentNavigation {
            browser.prepareRemoteBrowserStore(machineID: machineID)
            browser.bindRemoteBrowserNavigation()
            browser.remoteAccess.adoptCommittedRoute(model: model, url: logicalURL, resourceID: resourceID)
            model.connect()
        } else {
            browser.configureRemoteBrowser(model: model, url: logicalURL, resourceID: resourceID, request: request)
        }
        materializedPanels.insert(browser.id)
        catalog.tuiBrowserDocumentDidChange(browser)
        return true
    }

    private static func port(for resource: SurfaceResourceID, catalog: SurfaceCatalog) -> Int? {
        if resource.kind == .browser, !resource.key.hasPrefix("port:") { return nil }
        if let port = catalog.resources[resource]?.port { return port }
        if resource.kind == .browser, resource.key.hasPrefix("port:"),
           let port = Int(resource.key.dropFirst("port:".count)) {
            return port
        }
        return nil
    }

    /// Re-runs the authoritative machine refresh before retrying a route that
    /// was unavailable at materialization time (most commonly a withdrawn
    /// private address). The browser card therefore always has a real retry
    /// action instead of leaving the user on a dead loading surface.
    /// Leaves a recoverable placeholder when a route cannot be materialized yet.
    /// The retry refreshes the machine metadata before resolving the resource,
    /// which repairs stale or missing private addresses during session restore.
    func showPortUnavailable(_ message: String, resourceID: SurfaceResourceID, browser: BrowserPanel) {
        browser.remoteAccess.showUnavailable(message) { [weak self, weak browser] request in
            guard let self, let browser, self.isRegisteredInCatalog() else { return }
            let lifecycle = self.currentLifecycleGeneration
            do {
                await self.refresh(force: true)
                guard self.isCurrentLifecycleGeneration(lifecycle), self.isRegisteredInCatalog(),
                      browser.remoteAccess.isCurrentUnavailableRetry(request) else { return }
                let resource = self.catalog.resources[resourceID]
                    ?? resourceID.forwardedPort.map { CmuxTuiSnapshotParser.portBrowser(machine: self.machine, port: $0) }
                guard let resource, resource.machine == self.machine else { throw SurfaceCatalogError.unknownResource(resourceID) }
                if let browserURL = self.remoteBrowserOriginURL(for: resource, restoring: browser) {
                    let configured = self.configureBrowser(browser, url: browserURL, resourceID: resourceID)
                    if configured { browser.pendingRemoteRestoreURL = nil }
                    return
                }
                switch TuiPortRoutePlan.plan(resource: resource, privateAddress: self.info.privateAddress) {
                case .privateDirect(let raw):
                    guard let url = URL(string: raw) else { throw ProviderError.invalidPreviewURL }
                    let restoredURL = browser.remoteRestoreURL(on: url)
                    let configured = self.configureBrowser(browser, url: restoredURL, resourceID: resourceID)
                    if configured { browser.pendingRemoteRestoreURL = nil }
                case .unsupported(let nextMessage):
                    self.showPortUnavailable(nextMessage, resourceID: resourceID, browser: browser)
                }
            } catch {
                guard self.isCurrentLifecycleGeneration(lifecycle), self.isRegisteredInCatalog(),
                      browser.remoteAccess.isCurrentUnavailableRetry(request) else { return }
                self.showPortUnavailable(RemoteMachineLink.errorText(error), resourceID: resourceID, browser: browser)
            }
        }
    }

    func accessModel(
        port: Int,
        address: String,
        targetHost: String? = nil,
        scheme: String = "http",
        route: RemotePortAccessRoute = .loopback,
        preservesRemoteHost: Bool = false
    ) -> RemotePortAccessModel {
        let target = RemotePortForwardTarget(host: targetHost ?? address, port: port)
        return portAccessStore.model(machineID: machineID, target: target, scheme: scheme) {
            RemotePortAccessModel(
                target: target,
                wake: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw CancellationError() }
                },
                startForward: { [links, machine, machineID] target in
                    try await links.loopbackForward(machineID: machineID, port: target.port) {
                        Task { @MainActor in
                            (SurfaceCatalog.shared.provider(for: machine) as? CmuxTuiSurfaceProvider)?
                                .restartSSHForward(port: target.port)
                        }
                    }
                },
                stopForward: { [links, machineID] in
                    await links.closeLoopbackForward(machineID: machineID, port: port)
                },
                route: .loopback
            )
        }
    }

    /// The SSH service behind one of this machine's forward listeners, so a
    /// listener URL opened in another pane reaches the service, not that port.
    func sshServiceURL(forForwardListener url: URL) -> URL? {
        guard machine.isSSH,
              PrivateNetworkHostPolicy().isLoopback(host: url.host ?? ""),
              let port = url.port else { return nil }
        for (key, model) in portAccessStore.models where key.machineID == machineID {
            guard case .forwarded(let localPort) = model.phase, Int(localPort) == port,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            parts.port = model.target.port
            return parts.url
        }
        return nil
    }

    /// A forward whose child exited reconnects on a new listener, and the panes
    /// on it follow, instead of pointing at a port this Mac no longer owns.
    func restartSSHForward(port: Int) {
        for (key, model) in portAccessStore.models where key.machineID == machineID && key.port == port {
            model.retry()
        }
    }

    /// A settled scan is the authority for staged restored port panes: a port
    /// it did not find is not listening, so that pane stops showing progress.
    func settleRestoredPortPanes(scannedPorts: [Int]) {
        let scanned = Set(scannedPorts)
        for projection in catalog.pendingRestoredProjections.projections where projection.resource.machine == machine {
            // Scans omit internal and display ports, so their absence proves nothing.
            guard let port = projection.resource.forwardedPort, !scanned.contains(port),
                  !CmuxTuiSnapshotParser.internalPorts.contains(port),
                  let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID)
            else { continue }
            browser.remoteAccess.failRestore(String(
                localized: "ssh.browser.restoreUnavailable",
                defaultValue: "This SSH browser service is unavailable. Refresh its host to reconnect."
            ))
        }
    }

    /// Rebinds browser panes for the supplied resources, or all restored browser panes.
    func reprojectRestoredBrowserPanes(generation: UInt64, resourceIDs: Set<SurfaceResourceID>? = nil) {
        let projectionsByResource = resourceIDs.map { catalog.projections(of: $0) }
        for resource in catalog.snapshot.resources(on: machine) where
            resource.kind != .terminal && (resourceIDs == nil || resourceIDs!.contains(resource.id)) {
            for projection in (resourceIDs == nil ? catalog.projections(of: resource.id) : projectionsByResource?[resource.id] ?? []) where !materializedPanels.contains(projection.panelID) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID),
                      isCurrentLifecycleGeneration(generation), catalog.canRestoreProjection(projection) else { continue }
                if let loopbackURL = remoteLoopbackBrowserURL(for: resource) {
                    let configured = configureBrowser(browser, url: browser.remoteRestoreURL(on: loopbackURL), resourceID: resource.id)
                    if configured {
                        browser.pendingRemoteRestoreURL = nil
                        materializedPanels.insert(projection.panelID)
                    }
                    continue
                }
                if let browserURL = remoteBrowserOriginURL(for: resource, restoring: browser) {
                    let configured = configureBrowser(
                        browser,
                        url: browser.remoteRestoreURL(on: browserURL),
                        resourceID: resource.id
                    )
                    if configured {
                        browser.pendingRemoteRestoreURL = nil
                        materializedPanels.insert(projection.panelID)
                    }
                    continue
                }
                switch TuiPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    guard let url = URL(string: raw) else { continue }
                    let configured = configureBrowser(
                        browser,
                        url: browser.remoteRestoreURL(on: url),
                        resourceID: resource.id
                    )
                    if configured {
                        browser.pendingRemoteRestoreURL = nil
                        materializedPanels.insert(projection.panelID)
                    }
                case .unsupported(let message):
                    if resource.id.isForwardedPort {
                        showPortUnavailable(message, resourceID: resource.id, browser: browser)
                    }
                    // A later SSH port scan may resolve this saved service route.
                    continue
                }
            }
        }
    }

    /// Copying a link is read-only and always returns the private address.
    func portLinkURL(port: Int) async throws -> String {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port)
        switch TuiPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let url): return url
        case .unsupported(let message): throw SurfaceCatalogError.unsupported(message)
        }
    }


}


extension CmuxTuiSurfaceProvider {
    /// A Cloud daemon browser keeps its loopback origin and uses the authenticated
    /// loopback forward instead of rewriting it to the machine private address.
    func remoteLoopbackBrowserURL(for resource: SurfaceResource) -> URL? {
        guard machine.tuiMachineID != nil, resource.kind == .browser,
              let raw = resource.url, let url = URL(string: raw),
              RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? "") else { return nil }
        return url
    }

    /// A daemon browser restores its saved document before resolving a route.
    /// The catalog can still contain the about:blank URL used at creation while
    /// the native pane has since navigated to a guest-local or public origin.
    func remoteBrowserOriginURL(for resource: SurfaceResource, restoring browser: BrowserPanel? = nil) -> URL? {
        guard machine.tuiMachineID != nil, resource.kind == .browser,
              !resource.id.key.hasPrefix("port:"), resource.remoteViews?.isEmpty == false else { return nil }
        let resource = catalog.resourceWithTuiBrowserDocument(resource)
        let catalogURL = resource.url.flatMap { URL(string: $0) } ?? SurfacePaneFactory.blankURL
        let url = browser?.remoteRestoreURL(on: catalogURL) ?? catalogURL
        if url == SurfacePaneFactory.blankURL { return url }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
