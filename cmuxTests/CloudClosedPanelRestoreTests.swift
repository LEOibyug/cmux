import Bonsplit
import CmuxRemoteSession
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudClosedPanelRestoreTests {

    @Test("Restoring a Cloud terminal reserves a manual mirror instead of a local shell")
    func tuiTerminalRestoreDoesNotBrieflyBecomeLocal() throws {
        try withManager(registeredWithApp: true) { manager in
            let workspace = manager.addWorkspace(initialSurface: .terminal)
            let oldID = try #require(workspace.focusedPanelId)
            let resource = SurfaceResourceID(machine: TuiTestHost(destination: "restore-\(UUID()).example.test").machine, kind: .terminal, key: "terminal-restore")
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.surfaceProjections = [SurfaceProjectionRecord(panelID: oldID, resource: resource, remoteWorkspaceID: "remote-workspace", remoteTabID: "remote-tab")]
            let remap = workspace.restoreSessionSnapshot(snapshot)
            let restoredID = try #require(remap[oldID])
            let panel = try #require(workspace.panels[restoredID] as? TerminalPanel)
            #expect(panel.surface.ioMode == .manualMirror)
            #expect(workspace.tuiPendingCreations[restoredID] != nil)
            #expect(SurfaceCatalog.shared.projectionRecords(forWorkspace: workspace.id).contains { $0.panelID == restoredID && $0.resource == resource })
        }
    }

    @Test("Closing a deferred Cloud browser keeps the last pane empty until reopen")
    func deferredBrowserReopensWithoutTerminal() throws {
        try withManager(registeredWithApp: true) { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser)
            let browserID = try #require(workspace.focusedPanelId)
            let resource = SurfaceResourceID(machine: TuiTestHost(destination: "browser-\(UUID()).example.test").machine, kind: .browser, key: "browser-1")
            let record = SurfaceProjectionRecord(
                panelID: browserID, resource: resource,
                remoteWorkspaceID: "remote-workspace", remoteTabID: "remote-tab"
            )
            var snapshot = workspace.sessionSnapshot(includeScrollback: false)
            snapshot.surfaceProjections = [record]
            let remap = workspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let deferredID = try #require(remap[browserID])
            #expect(workspace.panels[deferredID] is DeferredBrowserPanel)
            var closingID = deferredID
            for _ in 0..<2 {
                workspace.markCloseHistoryEligible(panelId: closingID)
                #expect(workspace.closePanel(closingID, force: true))
                #expect(workspace.panels.isEmpty)
                #expect(workspace.bonsplitController.allPaneIds.count == 1)
                #expect(manager.reopenMostRecentlyClosedItem())
                let restoredID = try #require(workspace.focusedPanelId)
                #expect(workspace.panels.count == 1)
                #expect(workspace.panels[restoredID]?.panelType == .browser)
                let records = SurfaceCatalog.shared.projectionRecords(forWorkspace: workspace.id)
                let restored = try #require(records.first { $0.panelID == restoredID })
                #expect(restored.resource == resource)
                #expect(restored.remoteWorkspaceID == "remote-workspace")
                #expect(restored.remoteTabID == "remote-tab")
                closingID = restoredID
            }
        }
    }

    @Test("History remaps layout-only references and persists the revision")
    func anchorRemappingIncludesLayoutOnlyReferences() throws {
        try withManager { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser)
            let snapshot = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first)
            let oldID = UUID(), newID = UUID()
            let layout = SessionWorkspaceLayoutSnapshot.split(SessionSplitLayoutSnapshot(
                orientation: .vertical, dividerPosition: 0.35,
                first: .pane(SessionPaneLayoutSnapshot(panelIds: [oldID], selectedPanelId: oldID, isFullWidthTabMode: true)),
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [snapshot.id], selectedPanelId: snapshot.id))
            ))
            let store = ClosedItemHistoryStore(loadPersisted: false)
            store.push(.panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id, paneId: UUID(), tabIndex: 0,
                snapshot: snapshot, layout: layout
            )))
            let revision = store.revision
            store.remapPanelAnchorIds(from: oldID, to: newID)
            #expect(store.revision == revision + 1)
            let didRestore = store.restoreFirstRestorable { entry in
                guard case .panel(let panel) = entry,
                      case .split(let split)? = panel.layout,
                      case .pane(let first) = split.first else {
                    Issue.record("Expected saved nested layout")
                    return false
                }
                #expect(first.panelIds == [newID])
                #expect(first.selectedPanelId == newID)
                #expect(first.isFullWidthTabMode == true)
                #expect(split.dividerPosition == 0.35)
                return true
            }
            #expect(didRestore)
        }
    }

    @Test("Reopen retains panes and tabs created after the history snapshot")
    func unrelatedTopologySurvivesReopen() throws {
        try withManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let sourceID = try #require(workspace.focusedPanelId)
            let browserID = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: sourceID,
                orientation: .horizontal, url: URL(string: "about:blank")
            ))
            workspace.markCloseHistoryEligible(panelId: browserID)
            #expect(workspace.closePanel(browserID, force: true))
            let addedID = try #require(workspace.newTerminalSplit(
                from: sourceID, orientation: .vertical, focus: false
            )?.id)
            let addedPane = try #require(workspace.paneId(forPanelId: addedID))
            let addedTab = try #require(workspace.newTerminalSurface(inPane: addedPane, focus: false)?.id)
            let sourcePane = try #require(workspace.paneId(forPanelId: sourceID))
            #expect(manager.reopenMostRecentlyClosedItem())
            #expect(workspace.paneId(forPanelId: sourceID) == sourcePane)
            #expect(workspace.paneId(forPanelId: addedID) == addedPane)
            #expect(workspace.paneId(forPanelId: addedTab) == addedPane)
            #expect(workspace.panels.values.filter { $0.panelType == .browser }.count == 1)
            #expect(workspace.panels.count == 4)
        }
    }

    @Test("Reopen from another workspace restores the collapsed browser split")
    func collapsedBrowserSplitReopensInItsOwnPane() throws {
        try withManager { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let sourceID = try #require(workspace.focusedPanelId)
            let browserID = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: sourceID,
                orientation: .horizontal, url: URL(string: "about:blank")
            ))
            #expect(workspace.closePanel(browserID, force: true))
            let panelIDsBeforeReopen = Set(workspace.panels.keys)
            let other = manager.addWorkspace()
            #expect(manager.selectedTabId == other.id)
            #expect(manager.reopenMostRecentlyClosedBrowserPanel())
            let newIDs = Set(workspace.panels.keys).subtracting(panelIDsBeforeReopen)
            #expect(newIDs.count == 1)
            let reopenedID = try #require(newIDs.first)
            #expect(workspace.panels[reopenedID] is BrowserPanel)
            #expect(manager.selectedTabId == workspace.id)
            #expect(workspace.focusedPanelId == reopenedID)
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
            let sourcePane = try #require(workspace.paneId(forPanelId: sourceID))
            let browserPane = try #require(workspace.paneId(forPanelId: reopenedID))
            #expect(sourcePane != browserPane)
        }
    }

    @Test("Nested browser-only history scaffolding does not trigger terminal creation")
    func nestedBrowserLayoutReopensWithoutTerminals() throws {
        try withManager { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser)
            let first = try #require(workspace.focusedPanelId)
            let second = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: first,
                orientation: .horizontal, url: URL(string: "about:blank")
            ))
            let third = try #require(manager.newBrowserSplit(
                tabId: workspace.id, fromPanelId: second,
                orientation: .vertical, url: URL(string: "about:blank")
            ))
            workspace.markCloseHistoryEligible(panelId: third)
            #expect(workspace.closePanel(third, force: true))
            #expect(manager.reopenMostRecentlyClosedItem())
            #expect(workspace.panels.count == 3)
            #expect(workspace.panels.values.allSatisfy { $0.panelType == .browser })
            #expect(workspace.bonsplitController.allPaneIds.count == 3)
            #expect(workspace.isProgrammaticSplit == false)
            guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
                  case .split(let nested) = root.second else {
                Issue.record("Expected horizontal split containing a nested vertical split")
                return
            }
            #expect(root.orientation == "horizontal")
            #expect(nested.orientation == "vertical")
        }
    }

    @Test("Only daemon browsers retain Cloud routing for external pages", arguments: [false, true])
    func externalNavigationBelongsOnlyToDaemonBrowser(daemonBrowser: Bool) throws {
        try withCloudBrowser(daemonBrowser: daemonBrowser) { _, browser, provider, resource in
            browser.remoteAccess.retainResource(resource.id)
            browser.prepareRemoteBrowserStore(machineID: provider.machineID)
            let external = try #require(URL(string: "https://external.example.test/"))
            #expect((browser.privateAddressRouteProvider(for: external) === provider) == daemonBrowser)
            #expect(browser.privateAddressRouteProvider(for: URL(string: "http://localhost:3000/")!) === provider)
            browser.leaveRemoteResourceForLocalNavigation()
            #expect(browser.privateAddressRouteProvider(for: external) == nil,
                    "A retained store or workspace binding alone cannot capture an external page")
        }
    }

    @Test("A saved daemon document restores when the catalog still says about:blank",
          arguments: ["session", "projection", "reconnect"],
          ["http://localhost:3000/document?step=2#saved", "https://saved.example.test/document?step=2#saved"])
    func blankDaemonResourceKeepsSavedDocument(path: String, savedAddress: String) throws {
        try withCloudBrowser { workspace, browser, provider, resource in
            let saved = try #require(URL(string: savedAddress))
            let catalog = SurfaceCatalog.shared
            let restored: BrowserPanel
            if path == "session" {
                var snapshot = workspace.sessionSnapshot(includeScrollback: false)
                snapshot.panels[0].browser?.urlString = savedAddress
                snapshot.panels[0].browser?.remoteResource = resource.id
                snapshot.surfaceProjections = [SurfaceProjectionRecord(
                    panelID: browser.id, resource: resource.id,
                    remoteWorkspaceID: "ws-browser-restore", remoteTabID: "tab-browser-restore"
                )]
                let remap = workspace.restoreSessionSnapshot(snapshot)
                let restoredID = try #require(remap[browser.id])
                restored = try #require(workspace.browserPanel(for: restoredID))
                // A hidden/disabled browser activates this same saved resource on reveal.
                restored.restoreRemoteResource(resource.id, preferredURL: saved)
            } else {
                restored = browser
                browser.remoteAccess.retainResource(resource.id)
                browser.pendingRemoteRestoreURL = saved
                catalog.record(SurfaceProjection(
                    resource: resource.id, workspaceID: workspace.id, panelID: browser.id,
                    remoteWorkspaceID: "ws-browser-restore", remoteTabID: "tab-browser-restore"
                ))
                if path == "projection" {
                    provider.reprojectRestoredBrowserPanes(generation: provider.currentLifecycleGeneration)
                } else {
                    provider.refreshTuiBrowserRoutes()
                }
            }
            if saved.scheme == "https" {
                #expect(restored.remoteAccess.error != nil)
                #expect(restored.remoteAccess.model == nil)
                #expect(restored.pendingRemoteRestoreURL == saved,
                    "An unsupported SSH route must preserve the saved document for an explicit retry")
                return
            }
            #expect(restored.remoteAccess.remoteURL == saved)
            #expect(restored.remoteAccess.model?.usesRemoteNetwork == true)
            #expect(restored.remoteAccess.resourceID == resource.id)
            #expect(restored.pendingRemoteRestoreURL == nil)
            #expect(workspace.pendingTuiBrowserPanelIDs.isEmpty)
            #expect(catalog.projectionRecord(forPanel: restored.id)?.resource == resource.id)
            #expect(catalog.resources[resource.id]?.url == "about:blank")
            let captured = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == restored.id })
            #expect(captured.browser?.remoteResource == resource.id)
            #expect(captured.browser?.urlString == savedAddress)
        }
    }

    @Test("The Cloud row and a second browser view follow the native document",
          arguments: [false, true], ["", "about:blank", "Research"])
    func cloudSidebarFollowsNativeDocument(daemonBrowser: Bool, tabName: String) throws {
        try withCloudBrowser(daemonBrowser: daemonBrowser, tabName: tabName.isEmpty ? nil : tabName) { workspace, browser, provider, resource in
            let catalog = SurfaceCatalog.shared
            browser.remoteAccess.retainResource(resource.id)
            catalog.record(SurfaceProjection(
                resource: resource.id, workspaceID: workspace.id, panelID: browser.id,
                remoteWorkspaceID: "ws-browser-restore",
                remoteTabID: daemonBrowser ? "tab-browser-restore" : nil
            ))
            let document = try #require(URL(string: "http://search.example.test/results?q=test#page"))
            let originalWebView = browser.webView
            browser.showRemoteAddress(document)
            // A subsequent daemon refresh still contains the creation URL.
            catalog.upsert(resource, from: provider)
            let row = try #require(catalog.snapshot.resources.first { $0.id == resource.id })
            if !daemonBrowser {
                #expect(row.url == resource.url, "Port previews cannot publish unrelated local navigation")
                return
            }
            #expect(row.url == document.absoluteString)
            let target = try #require(provider.remoteBrowserOriginURL(for: resource))
            #expect(target == document)
            let viewer = BrowserPanel(workspaceId: workspace.id, websiteDataStore: .nonPersistent())
            defer { viewer.close() }
            #expect(provider.configureBrowser(viewer, url: target, resourceID: resource.id))
            #expect(viewer.remoteAccess.remoteURL == document)
            #expect(viewer.remoteAccess.resourceID == resource.id)
            #expect(viewer.remoteAccess.model?.usesRemoteNetwork == true)
            #expect(browser.webView === originalWebView, "Publishing metadata must not reload the source")
            catalog.endProjections(panelID: browser.id, reason: .replaced)
            #expect(catalog.snapshot.resources.first { $0.id == resource.id }?.url == resource.url)
        }
    }

    @Test("Restored browser metadata is seeded and survives route reconnection",
          arguments: ["preloaded", "legacy", "pending", "reconnect"])
    func restoredBrowserDocumentReachesSidebar(path: String) throws {
        try withCloudBrowser(tabName: "about:blank") { workspace, browser, provider, resource in
            let catalog = SurfaceCatalog.shared
            let document = try #require(URL(string: "http://restore.example.test/document"))
            browser.remoteAccess.retainResource(resource.id)
            if path == "preloaded" { browser.showRemoteAddress(document) }
            let projection = SurfaceProjection(
                resource: resource.id, workspaceID: workspace.id, panelID: browser.id,
                remoteWorkspaceID: "ws-browser-restore",
                remoteTabID: path == "legacy" || path == "pending" ? nil : "tab-browser-restore"
            )
            if path == "pending" {
                catalog.pendingRestoredProjections.stage(SurfaceProjectionRecord(
                    panelID: browser.id, resource: resource.id,
                    remoteWorkspaceID: projection.remoteWorkspaceID, remoteTabID: nil
                ), workspaceID: workspace.id)
            } else {
                catalog.record(projection)
            }
            if path != "preloaded" { browser.showRemoteAddress(document) }
            if path == "reconnect" {
                let replacement = CmuxTuiSurfaceProvider(summary: provider.summary,
                    links: TuiTestHost(connection: provider.summary.connection).links(),
                    catalog: catalog, browserPolicy: { .init(managedPatterns: nil) })
                catalog.register(replacement)
                // The document has not changed, so its didSet hook cannot seed the new provider.
                #expect(replacement.configureBrowser(browser, url: document, resourceID: resource.id,
                    preserveCurrentNavigation: true))
            }
            let row = try #require(catalog.snapshot.resources.first { $0.id == resource.id })
            #expect(row.url == document.absoluteString)
            catalog.endProjections(panelID: browser.id, reason: .replaced)
            #expect(catalog.snapshot.resources.first { $0.id == resource.id }?.url == resource.url)
        }
    }

    @Test("An untouched daemon browser opens as a blank browser instead of a port failure")
    func blankDaemonBrowserDoesNotNeedAPort() throws {
        try withCloudBrowser { workspace, _, provider, resource in
            let target = try #require(provider.remoteBrowserOriginURL(for: resource))
            #expect(target == SurfacePaneFactory.blankURL)
            let viewer = BrowserPanel(workspaceId: workspace.id, websiteDataStore: .nonPersistent())
            defer { viewer.close() }
            #expect(provider.configureBrowser(viewer, url: target, resourceID: resource.id))
            #expect(viewer.remoteAccess.resourceID == resource.id)
            #expect(viewer.remoteAccess.model == nil)
            #expect(viewer.remoteAccess.error == nil)
            #expect(!viewer.shouldRenderWebView)
        }
    }

    private func withCloudBrowser(
        daemonBrowser: Bool = true,
        tabName: String? = nil,
        _ body: (Workspace, BrowserPanel, CmuxTuiSurfaceProvider, SurfaceResource) throws -> Void
    ) throws {
        try withManager(registeredWithApp: true) { manager in
            let workspace = manager.addWorkspace(initialSurface: .browser)
            let panelID = try #require(workspace.focusedPanelId)
            let browser = try #require(workspace.browserPanel(for: panelID))
            let host = TuiTestHost(destination: "browser-restore-\(UUID()).example.test")
            let machineID = host.machine.rawValue
            workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: machineID,
                remoteWorkspaceID: "ws-browser-restore")
            let catalog = SurfaceCatalog.shared
            let provider = CmuxTuiSurfaceProvider(summary: host.summary,
                links: host.links(),
                catalog: catalog, browserPolicy: { .init(managedPatterns: nil) })
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            let remote = SurfaceRemoteWorkspace(id: "ws-browser-restore", name: "browser", index: 0, focused: true)
            var resource = SurfaceResource(
                id: SurfaceResourceID(machine: provider.machine, kind: .browser,
                    key: daemonBrowser ? "browser-restore" : "port:3000"),
                title: "browser", detail: nil, lifecycle: .running, agent: nil,
                remoteWorkspace: remote, port: daemonBrowser ? nil : 3000,
                url: daemonBrowser ? "about:blank" : "http://localhost:3000/"
            )
            if daemonBrowser {
                resource.remoteViews = [SurfaceRemoteView(tabID: "tab-browser-restore", workspace: remote, name: tabName)]
            }
            catalog.upsert(resource, from: provider)
            try body(workspace, browser, provider, resource)
        }
    }

    private func withManager(registeredWithApp: Bool = false, _ body: (TabManager) throws -> Void) throws {
        let suite = "CloudClosedPanelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "closeWorkspaceOnLastSurfaceShortcut")
        let settings = AppCatalogSection()
        defaults.set(false, forKey: settings.warnBeforeClosingTab.userDefaultsKey)
        defaults.set(false, forKey: settings.warnBeforeClosingTabXButton.userDefaultsKey)
        let manager = TabManager(settings: UserDefaultsSettingsClient(defaults: defaults), closeTabWarningDefaults: defaults)
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            for workspace in manager.tabs {
                for panelID in workspace.panels.keys {
                    SurfaceCatalog.shared.endProjections(panelID: panelID, reason: .replaced)
                }
            }
            manager.finalizeAllWorkspacesForWindowClose()
            ClosedItemHistoryStore.shared.removeAll()
            defaults.removePersistentDomain(forName: suite)
        }
        guard registeredWithApp else { return try body(manager) }
        // `SurfaceCatalog.shared` restores projections only into a workspace the app resolves.
        try LiveWorkspaceFixture.withAppRegistration(of: manager) { try body(manager) }
    }
}
