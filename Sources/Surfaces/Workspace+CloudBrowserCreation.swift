import AppKit
import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension Workspace {
    struct TuiBrowserCreationRoute {
        let machine: SurfaceMachineID
        let remoteWorkspaceID: String?
        let screenID: String?
        let paneID: String?
        let url: URL
    }

    /// The value captured before a native browser placeholder is inserted.
    /// Both browser entrypoints use this plan so Cloud routing and unavailable
    /// handling cannot drift between split and tab creation.
    struct TuiBrowserCreationPlan {
        let route: TuiBrowserCreationRoute?
        let unavailable: Bool
        let unsupportedURL: Bool
        /// Session restore must not let WebKit load the saved URL before its
        /// Cloud resource is rebound to the machine provider.
        let suppressInitialNavigation: Bool
    }

    /// Resolves the remote target once for a browser creation intent. Restore
    /// uses the catalog's saved projection instead of issuing a new mutation.
    func tuiBrowserCreationPlan(
        sourcePanelID: UUID?,
        requestedURL: URL?,
        creationPolicy: BrowserPanelCreationPolicy
    ) -> TuiBrowserCreationPlan {
        let route = creationPolicy == .restoration
            ? nil
            : tuiBrowserCreationRoute(sourcePanelID: sourcePanelID, requestedURL: requestedURL)
        let requiresTuiBrowser = remoteWorkspaceBinding.map {
            SurfaceMachineID(rawValue: $0.machineID)?.isSSH == true
        } ?? false
        let unsupportedURL = requiresTuiBrowser && creationPolicy != .restoration &&
            requestedURL.map { !Self.tuiBrowserURLIsSupported($0) } == true
        return TuiBrowserCreationPlan(
            route: route,
            unavailable: creationPolicy != .restoration && requiresTuiBrowser && route == nil,
            unsupportedURL: unsupportedURL,
            suppressInitialNavigation: creationPolicy == .restoration && requiresTuiBrowser
        )
    }

    private static func tuiBrowserURLIsSupported(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "about": return true
        default: return false
        }
    }

    /// Returns a remote browser target only for a bound Cloud workspace. SSH
    /// workspaces continue through their existing browser path.
    func tuiBrowserCreationRoute(sourcePanelID: UUID?, requestedURL: URL?) -> TuiBrowserCreationRoute? {
        guard let binding = remoteWorkspaceBinding else { return nil }
        guard let machine = SurfaceMachineID(rawValue: binding.machineID), machine.isSSH,
              SurfaceCatalog.shared.provider(for: machine) is CmuxTuiSurfaceProvider else { return nil }
        let boundRemoteWorkspaceID: String? = {
            guard let value = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }()
        let sourceView: SurfaceRemoteView? = {
            guard let sourcePanelID,
                  let projection = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID),
                  projection.resource.machine == machine,
                  let resource = SurfaceCatalog.shared.resources[projection.resource] else { return nil }
            let views = resource.remoteViews ?? []
            if let tabID = projection.remoteTabID {
                // A local projection can outlive a workspace binding change. Do not
                // carry its old screen/pane across the newly selected remote
                // workspace; those IDs are only meaningful within that workspace.
                if let boundRemoteWorkspaceID {
                    return views.first {
                        $0.tabID == tabID && $0.workspace.id == boundRemoteWorkspaceID
                    }
                }
                return views.first(where: { $0.tabID == tabID })
            }
            if let boundRemoteWorkspaceID {
                return views.first(where: { $0.workspace.id == boundRemoteWorkspaceID })
            }
            return views.first
        }()
        let remoteWorkspaceID = boundRemoteWorkspaceID
            ?? sourceView?.workspace.id
            ?? (SurfaceCatalog.shared.provider(for: machine) as? CmuxTuiSurfaceProvider)?.info.remoteWorkspaces?.first(where: \.focused)?.id
        guard let remoteWorkspaceID, !remoteWorkspaceID.isEmpty else { return nil }
        let url = requestedURL ?? URL(string: "about:blank")!
        return TuiBrowserCreationRoute(
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            screenID: sourceView?.screenID,
            paneID: sourceView?.paneID,
            url: url
        )
    }

    /// Starts the remote create after the native tab has been inserted. The
    /// placeholder is kept free of a local URL until the daemon receipt binds it.
    func startTuiBrowserCreation(panel: BrowserPanel, route: TuiBrowserCreationRoute, name: String? = nil) {
        let catalog = SurfaceCatalog.shared
        guard let provider = catalog.provider(for: route.machine) as? CmuxTuiSurfaceProvider else { return }
        let mutation = catalog.tuiWorkspaceProjectionCoordinator.beginLocalMutation(on: route.machine)
        pendingTuiBrowserPanelIDs.insert(panel.id)
        let panelID = panel.id
        let requestID = UUID().uuidString.lowercased()
        let task = Task { @MainActor [weak self, weak panel, weak provider] in
            defer {
                catalog.tuiWorkspaceProjectionCoordinator.endLocalMutation(mutation, on: route.machine, catalog: catalog)
                if let self {
                    self.tuiBrowserCreationTasks.removeValue(forKey: panelID)
                    self.pendingTuiBrowserPanelIDs.remove(panelID)
                    self.tuiLayoutDidChange()
                }
            }
            guard let self, let panel else { return }
            do {
                guard !Task.isCancelled, self.panels[panel.id] === panel else { throw CancellationError() }
                guard let provider else {
                    throw CmuxTuiSurfaceProvider.ProviderError.stateUnavailable(route.machine.rawValue)
                }
                let created = try await provider.createBrowser(
                    url: route.url,
                    name: name,
                    remoteWorkspaceID: route.remoteWorkspaceID,
                    screenID: route.screenID,
                    paneID: route.paneID,
                    idempotencyKey: "cmux-cloud-browser-\(requestID)",
                    correlationKey: "cmux-cloud-browser-\(requestID)"
                )
                guard !Task.isCancelled, self.panels[panel.id] === panel,
                      let remoteView = created.remoteViews?.first else {
                    await self.cleanupCancelledTuiBrowser(created, provider: provider, catalog: catalog)
                    throw CancellationError()
                }
                guard let activeProvider = catalog.provider(for: route.machine) as? CmuxTuiSurfaceProvider,
                      activeProvider.isRegisteredInCatalog() else {
                    throw CmuxTuiSurfaceProvider.ProviderError.stateUnavailable(route.machine.rawValue)
                }
                // Adopt the daemon identity before configuring WebKit. If route
                // setup cannot start (for example, the proxy is unavailable),
                // the pane still owns the committed resource and can reconnect
                // it later instead of leaving an orphaned catalog row/tab.
                panel.retainTransferredSurfaceMachine(created.id.machine)
                panel.remoteAccess.retainResource(created.id)
                catalog.endProjections(panelID: panel.id, reason: .replaced)
                catalog.record(SurfaceProjection(
                    resource: created.id,
                    workspaceID: self.id,
                    panelID: panel.id,
                    remoteWorkspaceID: remoteView.workspace.id,
                    remoteTabID: remoteView.tabID
                ))
                if ["http", "https"].contains(route.url.scheme?.lowercased() ?? "") {
                    guard activeProvider.configureBrowser(panel, url: route.url, resourceID: created.id) else {
                        throw CmuxTuiSurfaceProvider.ProviderError.localForwardURLUnavailable
                    }
                } else if route.url.scheme?.lowercased() == "about" {
                    panel.remoteAccess.retainResource(created.id)
                } else {
                    throw CmuxTuiSurfaceProvider.ProviderError.localForwardURLUnavailable
                }
            } catch {
                guard !Task.isCancelled, self.panels[panel.id] === panel else { return }
                panel.remoteAccess.showUnavailable(String(localized: "cloud.browser.creationUnavailable", defaultValue: "Cloud browsers are unavailable on this machine. Refresh the machine and retry."))
            }
        }
        tuiBrowserCreationTasks[panel.id] = task
    }

    /// Applies the shared post-insertion action for split and tab entrypoints.
    func applyTuiBrowserCreationPlan(_ plan: TuiBrowserCreationPlan, to panel: BrowserPanel) {
        if plan.unsupportedURL {
            panel.remoteAccess.showUnavailable(String(
                localized: "cloud.portAccess.invalidURL",
                defaultValue: "This port does not have a valid HTTP or HTTPS address."
            ))
        } else if let route = plan.route {
            startTuiBrowserCreation(panel: panel, route: route)
        } else if plan.unavailable {
            panel.remoteAccess.showUnavailable(String(
                localized: "cloud.browser.creationUnavailable",
                defaultValue: "Cloud browsers are unavailable on this machine. Refresh the machine and retry."
            ))
        }
    }

    /// Compensates a committed daemon tab when the local placeholder closes
    /// while its cancellation-safe create is still awaiting the receipt.
    private func cleanupCancelledTuiBrowser(
        _ resource: SurfaceResource,
        provider: CmuxTuiSurfaceProvider,
        catalog: SurfaceCatalog
    ) async {
        guard let view = resource.remoteViews?.first else { return }
        // A replacement may compensate only for this same SSH host identity.
        let activeProvider = [
            catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider,
            provider,
        ].compactMap { $0 }.first {
            $0.machine == provider.machine && !$0.isRetired
        }
        guard let activeProvider else { return }
        let cleanup = Task { @MainActor in
            do {
                try await activeProvider.closeRemoteTab(id: view.tabID, inRemoteWorkspace: view.workspace.id)
            } catch {
                // Keep the receipt and optimistic row so the next refresh or
                // reconnect still has a handle to reconcile and close. Dropping
                // it here would orphan a daemon browser after a transient close
                // failure.
                activeProvider.publishPendingMutationMetadata()
                activeProvider.scheduleRefresh(force: true)
                return
            }
            activeProvider.pendingRemoteCreations.removeValue(forKey: resource.id)
            activeProvider.publishPendingMutationMetadata()
            catalog.remove(resource.id, from: activeProvider)
        }
        _ = await cleanup.result
    }
}
