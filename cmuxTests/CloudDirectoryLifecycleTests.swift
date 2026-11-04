import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud cwd and machine identity", .serialized)
@MainActor
struct CloudDirectoryLifecycleTests {
    @Test("A terminal finishing launch wakes the sidebar even when its cwd is unchanged")
    func launchCompletionWakesSidebar() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.install(paths: ["/home/cmux/first", "/home/cmux/second"], revision: 2,
                            lifecycles: ["launching", "launching"])
        #expect(try fixture.sidebarText().isEmpty)
        let directories = fixture.workspace.panelDirectories
        let launching = fixture.workspace.remoteBindingState.revision

        // The daemon reports readiness as a delta that repeats the same cwd.
        try fixture.changeDirectory("/home/cmux/first", terminal: 0)

        #expect(fixture.workspace.panelDirectories == directories)
        #expect(fixture.workspace.remoteBindingState.revision > launching,
                "The sidebar rebuild follows remote binding metadata changes")
        #expect(try fixture.sidebarText().contains("/home/cmux/first"))

        let ready = fixture.workspace.remoteBindingState.revision
        try fixture.changeDirectory("/home/cmux/first", terminal: 0)
        #expect(fixture.workspace.remoteBindingState.revision == ready,
                "An unchanged presentation must not rebuild the row again")
    }

    @Test("Terminal-only cd deltas update focused and background panels without title changes")
    func liveDirectoryDelta() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let first = fixture.panels[0]
        let second = fixture.panels[1]
        try fixture.changeDirectory("/srv/focused", terminal: 0)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/focused")
        #expect(fixture.workspace.reportedPanelDirectory(panelId: first) == "/srv/focused")
        #expect(fixture.catalog.resources[fixture.resourceID(0)]?.detail == "/srv/focused")
        #expect(try fixture.sidebarText().contains("focused"))

        try fixture.changeDirectory("/srv/background", terminal: 1)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: second) == "/srv/background")
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/focused")
        #expect(try fixture.sidebarText().contains("background"))
        fixture.workspace.focusPanel(second)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/background")
        #expect(fixture.workspace.title == "My explicit task title")
        #expect(try !fixture.sidebarText().contains("local-checkout"))
    }

    @Test("Remote cd updates an unselected workspace without changing selection")
    func unselectedWorkspace() throws {
        let fixture = try CloudDirectoryTestFixture()
        let manager = TabManager(createInitialWorkspace: false)
        let selected = Workspace()
        manager.tabs = [fixture.workspace, selected]
        manager.selectedTabId = selected.id
        defer {
            fixture.close()
            for panel in selected.panels.values { panel.close() }
            manager.tabs = []
        }
        try fixture.changeDirectory("/srv/unselected", terminal: 0)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/unselected")
        #expect(try fixture.sidebarText().contains("unselected"))
        #expect(manager.selectedTabId == selected.id)
    }

    @Test("Missing remote cwd is explicit and cannot resurrect launch, git or PR metadata")
    func missingDirectory() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory(nil, terminal: 0)
        try fixture.changeDirectory(nil, terminal: 1)
        let workspace = fixture.workspace
        #expect(workspace.presentedCurrentDirectory == nil)
        #expect(!workspace.updatePanelDirectory(panelId: fixture.panels[0], directory: "/Users/alice/local-checkout"))
        workspace.updatePanelGitBranch(panelId: fixture.panels[0], branch: "local-only", isDirty: true)
        workspace.updatePanelPullRequest(panelId: fixture.panels[0], number: 4, label: "PR", url: try #require(URL(string: "https://github.com/example/local/pull/4")), status: .open)
        let sidebar = try fixture.sidebar()
        #expect(sidebar.finderDirectoryPath == nil)
        #expect(sidebar.compactGitBranchSummaryText == nil)
        #expect(sidebar.pullRequestRows.isEmpty)
        let text = try fixture.sidebarText()
        #expect(!text.contains("Directory unavailable"))
        #expect(!text.contains("local-checkout"))
        #expect(!text.contains("first"))
        fixture.catalog.markTuiStateStale(on: fixture.machine, reason: "reconnecting")
        let stale = fixture.catalog.snapshot
        let staleResource = try #require(stale.resources.first { $0.id == fixture.resourceID(0) })
        #expect(staleResource.detail == nil)
    }

    @Test("Launching Cloud terminals do not render a directory placeholder")
    func launchingDirectoryIsOmitted() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.install(paths: [nil, nil], revision: 2, lifecycles: ["launching", "launching"])

        #expect(try fixture.sidebarText().isEmpty)
    }

    @Test("A running Cloud terminal without cwd keeps its own placeholder beside a launching terminal")
    func mixedLaunchingAndRunningDirectoryStates() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.install(paths: [nil, nil], revision: 2, lifecycles: ["launching", "running"])

        #expect(try fixture.sidebarText().isEmpty)
    }

    @Test("A stale Cloud terminal without an accepted cwd does not render a placeholder")
    func staleMissingDirectoryIsOmitted() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.install(paths: [nil, nil], revision: 2, lifecycles: ["running", "running"])
        fixture.catalog.markTuiStateStale(on: fixture.machine, reason: "reconnecting")

        #expect(try fixture.sidebarText().isEmpty)
    }

    @Test("A missing terminal cwd uses another accepted terminal cwd on the machine")
    func missingDirectoryUsesMachineFallback() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.install(paths: [nil, "/home/cmux"], revision: 2, lifecycles: ["running", "running"])

        #expect(try fixture.sidebarText().contains("/home/cmux"))
    }

    @Test("An unconfirmed Cloud terminal withholds its requested cwd until the machine's state is current")
    func unconfirmedCloudDirectoryIsWithheld() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        // A terminal the app just asked a machine for carries the requested
        // directory, but that machine's provider has not accepted any state yet.
        let host = TuiTestHost(destination: "unconfirmed.example.test")
        let unconfirmed = host.machine
        let provider = CmuxTuiSurfaceProvider(
            summary: host.summary, links: host.links(), catalog: fixture.catalog
        )
        fixture.catalog.register(provider)
        defer { fixture.catalog.unregister(machine: unconfirmed) }
        let requested = SurfaceResourceID(machine: unconfirmed, kind: .terminal, key: "term_requested")
        fixture.catalog.upsert(SurfaceResource(
            id: requested, title: "", detail: "/srv/requested", lifecycle: .launching,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        ), from: provider)
        let local = SurfaceResourceID(machine: .local, kind: .terminal, key: "local-term")
        fixture.catalog.upsert(SurfaceResource(
            id: local, title: "", detail: "/Users/alice/project", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        ))

        let snapshot = fixture.catalog.snapshot
        let presented = try #require(snapshot.resources.first { $0.id == requested })
        #expect(presented.detail == nil)
        #expect(fixture.catalog.resources[requested]?.detail == "/srv/requested")
        // Confirmed Cloud terminals and local terminals keep their directories.
        #expect(snapshot.resources.first { $0.id == fixture.resourceID(0) }?.detail == "/home/cmux/first")
        #expect(snapshot.resources.first { $0.id == local }?.detail == "/Users/alice/project")
    }

    @Test("A stale graph keeps the last accepted cwd until a fresh snapshot replaces it")
    func reconnectAndStalePublication() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let old = try #require(fixture.provider.tuiState)
        try fixture.changeDirectory("/srv/resumed", terminal: 0)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[1]) == "/home/cmux/second")
        fixture.catalog.markTuiStateStale(on: fixture.machine, reason: "reconnecting")
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/resumed")
        #expect(fixture.catalog.snapshot.staleMachineIDs.contains(fixture.machine))
        let staleSnapshot = fixture.catalog.snapshot
        let staleResource = try #require(staleSnapshot.resources.first { $0.id == fixture.resourceID(0) })
        #expect(staleResource.detail == "/srv/resumed")
        #expect(try !fixture.sidebarText().contains("Directory unavailable"))
        #expect(try fixture.sidebarText().contains("/srv/resumed"))
        let current = try fixture.install(paths: ["/srv/reconnected", nil], revision: 1, generation: "replacement")
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/reconnected")
        #expect(!fixture.provider.installSnapshotIfNewer(old))
        fixture.provider.publish(old, ports: [])
        fixture.provider.publishDelta(old, impact: TuiStateDeltaImpact(resourceIDs: [fixture.resourceID(0)], requiresFullResourceRebuild: false), ports: [], reconcileTitles: false)
        #expect(fixture.catalog.tuiStates[fixture.machine] == current)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/reconnected")
    }

    @Test("A replacement provider accepts its cwd and ignores retired callbacks")
    func providerReplacement() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let old = try #require(fixture.provider.tuiState)
        fixture.catalog.markTuiStateStale(on: fixture.machine, reason: "provider replacement")
        let replacement = CmuxTuiSurfaceProvider(
            summary: fixture.host.summary,
            links: fixture.host.links(), catalog: fixture.catalog
        )
        fixture.catalog.register(replacement)
        let stale = fixture.catalog.snapshot
        #expect(stale.resources.first { $0.id == fixture.resourceID(0) }?.detail == "/home/cmux/first")

        let current = try fixture.state(paths: ["/srv/replacement", nil], revision: 1, generation: "replacement")
        #expect(replacement.installSnapshotIfNewer(current))
        replacement.publish(current, ports: [])
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/replacement")

        fixture.provider.publish(old, ports: [])
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/replacement")
        #expect(fixture.catalog.tuiStates[fixture.machine] == current)
    }

    @Test("Deleting a terminal clears its cached cwd")
    func deletedTerminalClearsDirectory() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        fixture.catalog.markTuiStateStale(on: fixture.machine, reason: "refresh")
        let current = try fixture.install(paths: ["/home/cmux/first"], revision: 2, generation: "replacement")
        #expect(current.lookupIndex.terminal(id: "term_1") == nil)
        #expect(fixture.catalog.snapshot.resources.contains { $0.id == fixture.resourceID(1) } == false)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[1]) == nil)
        let text = try fixture.sidebarText()
        #expect(!text.contains("Directory unavailable"))
        #expect(!text.contains("/home/cmux/second"))
    }

    @Test("An expired creation overlay cannot close a pane while its live tab is unresolved")
    func pendingCreationOverlayExpiryFencesPaneCleanup() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let panel = fixture.panels[1]
        let terminalID = fixture.resourceID(1)
        let session = TuiManualMirrorSession(
            machineID: fixture.machine.rawValue,
            terminalID: terminalID.key,
            remoteSurfaceID: 0,
            onNeedsReconnect: {}
        )
        fixture.provider.manualMirrorSessions[panel] = session
        defer { session.stop() }

        let resource = try #require(fixture.catalog.resources[terminalID])
        fixture.provider.pendingRemoteCreations[terminalID] = .init(
            resource: resource,
            receipt: .init(generation: "daemon", revision: 2),
            tabID: "tab_1"
        )
        var snapshot = try #require(fixture.provider.tuiState?.snapshotObject())
        snapshot["cursor"] = ["generation": "daemon", "revision": "2"]
        // Keep the live tab row while omitting its terminal row. This is an
        // incomplete accepted graph; the pending overlay is the only catalog
        // row that had been making the placement look complete.
        snapshot["terminals"] = [[
            "id": "term_0", "title": "bash", "lifecycle": "running"
        ]]
        let next = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: fixture.machine))
        #expect(fixture.provider.installSnapshotIfNewer(next))
        fixture.provider.publishDelta(
            next,
            impact: .init(resourceIDs: [fixture.resourceID(0)], requiresFullResourceRebuild: false),
            ports: [],
            reconcileTitles: false
        )

        #expect(fixture.catalog.resources[terminalID] == nil)
        #expect(fixture.provider.manualMirrorSessions[panel] === session)
        #expect(fixture.workspace.panels[panel] != nil)
    }

    @Test("Older and equal-cursor conflicting snapshots cannot overwrite a live cd")
    func outOfOrderReports() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let old = try #require(fixture.provider.tuiState)
        try fixture.changeDirectory("/srv/newest", terminal: 0)
        #expect(!fixture.provider.installSnapshotIfNewer(old))
        let conflict = try fixture.state(paths: ["/srv/old", nil], revision: 2)
        #expect(!fixture.provider.installSnapshotIfNewer(conflict))
        fixture.provider.publish(conflict, ports: [])
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/newest")
        #expect(TuiStateSyncDecision.forDelta(generation: "daemon", previousRevision: 1, revision: 2, current: fixture.provider.tuiState?.cursor) == .ignoreStale)
    }

    @Test("Machine names and stable IDs survive refresh and invalidate the immutable sidebar snapshot")
    func machineRename() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let revision = fixture.workspace.remoteBindingState.revision
        var info = fixture.provider.info
        info.name = "Build server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        #expect(fixture.workspace.remoteBindingState.machineNames[fixture.machine.rawValue] == "Build server")
        #expect(fixture.workspace.remoteWorkspaceBinding?.machineID == fixture.machine.rawValue)
        #expect(fixture.workspace.remoteBindingState.revision > revision)
        info.name = "Renamed server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        #expect(fixture.workspace.remoteBindingState.machineNames[fixture.machine.rawValue] == "Renamed server")
        #expect(fixture.workspace.title == "My explicit task title")
    }


    @Test("A renamed machine keeps its name while cwd is unavailable and safely falls back when cleared")
    func unavailableDirectoryMachineName() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory(nil, terminal: 0)
        try fixture.changeDirectory(nil, terminal: 1)
        for name in ["Build server", "Renamed server", "", " \n "] {
            var info = fixture.provider.info
            info.name = name
            fixture.catalog.updateMachine(info, from: fixture.provider)
            #expect(try fixture.sidebarText().isEmpty)
            #expect(fixture.workspace.remoteWorkspaceBinding?.machineID == fixture.machine.rawValue)
            #expect(fixture.workspace.remoteBindingState.machineNames[fixture.machine.rawValue] == name)
        }
    }

    @Test("Saved Cloud paths require fresh remote confirmation after restore")
    func sessionRestore() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let saved = fixture.workspace.sessionSnapshot(includeScrollback: false)
        let restored = Workspace(workingDirectory: "/Users/alice/launch")
        defer { for panel in restored.panels.values { panel.close() } }
        _ = restored.restoreSessionSnapshot(saved)
        #expect(restored.remoteWorkspaceBinding?.machineID == fixture.machine.rawValue)
        #expect(restored.remoteWorkspaceBinding?.remoteWorkspaceID == "ws_main")
        #expect(restored.title == "My explicit task title")
        #expect(restored.presentedCurrentDirectory == nil)
        #expect(restored.sidebarGitBranchesInDisplayOrder().isEmpty)
    }

    @Test("A projected terminal switches machine identity and cwd together")
    func resourceProjectionChanges() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.remoteWorkspaceBinding = nil
        let other = TuiTestHost(destination: "other.example.test").machine
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "other", "revision": "1"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "other", "title": "bash", "cwd": "/srv/other", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: other))
        var info = fixture.provider.info
        info.id = other
        info.name = "Other machine"
        fixture.catalog.replaceTuiState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        fixture.catalog.endProjections(panelID: fixture.panels[0], reason: .replaced)
        fixture.catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: other, kind: .terminal, key: "other"),
            workspaceID: workspace.id, panelID: fixture.panels[0]
        ))
        #expect(workspace.reportedPanelDirectory(panelId: fixture.panels[0]) == "/srv/other")
        #expect(workspace.remoteBindingState.projectedResources[fixture.panels[0]]?.machine == other)
        #expect(workspace.remoteBindingState.machineNames[other.rawValue] == "Other machine")
        #expect(workspace.title == "My explicit task title")
    }

    @Test("A machine name is shown once for multiple directories and collisions stay distinct")
    func groupedMachineDirectories() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory("/home/cmux/a", terminal: 0)
        try fixture.changeDirectory("/home/cmux/b", terminal: 1)
        var info = fixture.provider.info
        info.name = "Build server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        #expect(fixture.workspace.remoteBindingState.machineNames[fixture.machine.rawValue] == "Build server")
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[0]) == "/home/cmux/a")
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[1]) == "/home/cmux/b")

        let otherHost = TuiTestHost(destination: "other.example.test")
        let other = otherHost.machine
        let otherPanel = fixture.panels[1]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "other", "revision": "1"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "other-terminal", "title": "bash", "cwd": "/srv/other", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: other))
        let otherProvider = CmuxTuiSurfaceProvider(
            summary: otherHost.summary,
            links: otherHost.links(), catalog: fixture.catalog
        )
        fixture.catalog.register(otherProvider)
        defer {
            fixture.catalog.endProjections(panelID: otherPanel)
            fixture.catalog.unregister(machine: other)
        }
        var otherInfo = otherProvider.info
        otherInfo.name = "Build server"
        fixture.catalog.replaceTuiState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: otherInfo)
        fixture.catalog.endProjections(panelID: otherPanel, reason: .replaced)
        fixture.catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: other, kind: .terminal, key: "other-terminal"),
            workspaceID: fixture.workspace.id, panelID: otherPanel
        ))
        #expect(fixture.workspace.remoteBindingState.machineNames[fixture.machine.rawValue] == "Build server")
        #expect(fixture.workspace.remoteBindingState.machineNames[other.rawValue] == "Build server")
        #expect(fixture.workspace.remoteBindingState.projectedResources[fixture.panels[0]]?.machine == fixture.machine)
        #expect(fixture.workspace.remoteBindingState.projectedResources[otherPanel]?.machine == other)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[0]) == "/home/cmux/a")
        #expect(fixture.workspace.reportedPanelDirectory(panelId: otherPanel) == "/srv/other")
    }

    @Test("Local renderer OSC reports cannot overwrite the accepted Cloud graph")
    func localRendererCannotClaimRemoteProvenance() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer { for panel in workspace.panels.values { panel.close() }; manager.tabs = [] }
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: TuiTestHost(destination: "accepted.example.test").machine.rawValue)
        workspace.updateTuiPanelDirectory(panelId: panelID, directory: "/srv/accepted")
        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: panelID, directory: "/Users/alice/launcher")
        #expect(workspace.reportedPanelDirectory(panelId: panelID) == "/srv/accepted")
    }
}
