import CmuxRemoteSession
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
struct CloudMachineWorkspaceAdoptionTests {

    @Test("Reserved creation targets its loading card after the user focuses another pane")
    func reservedCreationDoesNotCloseFocusedUserPane() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let pending = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let loadingPanels = pending.panels.values.compactMap { $0 as? RemoteLoadingPanel }
            let loading = try #require(loadingPanels.count == 1 ? loadingPanels[0] : nil)
            let pane = try #require(pending.paneId(forPanelId: loading.id))
            let command = try #require(pending.newTerminalSurface(inPane: pane, focus: true,
                initialCommand: "echo user-content", autoRefreshMetadata: false))
            #expect(pending.focusedPanelId == command.id)

            let host = TuiWorkspaceCreationHost(manager: app.manager, reservedWorkspaceID: pending.id)
            let reservation = try host.reserve(title: "Cloud VM", machine: .ssh("e65b39c61d1c69b2184cd89464e454ac3309d01b30f591c283790934ea336d4b"), focus: false)

            #expect(reservation.panelID != command.id)
            #expect(pending.panels[command.id] === command)
            #expect(pending.panels[loading.id] == nil)
            #expect(pending.panels[reservation.panelID] is TerminalPanel)
        }
    }

    @Test("A create adopts the reserved workspace and tab once without selecting it")
    func adoptionAndReconnect() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let manager = app.manager
            let catalog = makeCatalog(manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            let pending = manager.addWorkspace(title: "New Machine", titleSource: .auto,
                initialSurface: .remoteLoading, select: false)
            let loading = try #require(pending.panels.values.first as? RemoteLoadingPanel)
            let tab = pending.surfaceIdFromPanelId(loading.id)
            let pane = pending.paneId(forPanelId: loading.id)
            let stableID = pending.stableId
            let selection = manager.selectedTabId
            #expect(pending.remoteWorkspaceBinding == nil)
            #expect(!pending.isRestorableInSessionSnapshot, "an uncommitted creating card cannot restore as a local shell")

            try provider.install(in: catalog)
            catalog.bindRemoteWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            #expect(pending.remoteWorkspaceBinding?.machineID == provider.machine.rawValue)
            #expect(pending.presentedCurrentDirectory == nil)
            let first = try await open(pending, provider: provider, catalog: catalog)
            #expect(first.panelID == loading.id)
            #expect(pending.remoteBindingState.projectedResources[first.panelID]?.machine == provider.machine)
            #expect(pending.surfaceIdFromPanelId(first.panelID) == tab)
            #expect(pending.paneId(forPanelId: first.panelID) == pane)
            #expect(pending.panels.count == 1)
            #expect(pending.stableId == stableID)
            #expect(pending.panels[first.panelID]?.stableSurfaceId == loading.stableSurfaceId)
            #expect(pending.terminalPanel(for: first.panelID)?.surface.initialCommand == nil)
            #expect(pending.remoteWorkspaceBinding?.remoteWorkspaceID == "ws-first")
            #expect(pending.title == "workspace-1")
            #expect(manager.selectedTabId == selection)

            let repeated = try await open(pending, provider: provider, catalog: catalog)
            #expect(repeated == first)
            #expect(provider.materializations == 1)
            try provider.install(in: catalog, generation: "reconnected")
            await catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
            #expect(catalog.projections == [first])
            var saved = pending.sessionSnapshot(includeScrollback: false)
            saved.surfaceProjections = catalog.projectionRecords(forWorkspace: pending.id)
            #expect(saved.remoteWorkspace?.remoteWorkspaceID == "ws-first")
            #expect(pending.isRestorableInSessionSnapshot)
            let restored = Workspace(initialSurface: .remoteLoading)
            defer { restored.teardownAllPanels() }
            restored.restoreSessionSnapshot(saved)
            #expect(restored.remoteWorkspaceBinding == pending.remoteWorkspaceBinding)
            #expect(restored.title == "workspace-1")
        }
    }

    @Test("Daemon failure keeps only its creating card; retry adopts it and later workspaces stay separate")
    func failureAndLaterWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let manager = app.manager
            let catalog = makeCatalog(manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let first = manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let second = manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let loading = try #require(first.panels.values.first as? RemoteLoadingPanel)
            catalog.bindRemoteWorkspace(localWorkspaceID: first.id, machine: provider.machine, remoteWorkspaceID: nil)
            provider.beforeMaterialization = { throw TuiTransportError.connectionClosed }
            await #expect(throws: TuiTransportError.self) { try await open(first, provider: provider, catalog: catalog) }
            #expect(first.panels[loading.id] === loading)
            #expect(catalog.projections.isEmpty)
            provider.beforeMaterialization = nil
            let attached = try await open(first, provider: provider, catalog: catalog)
            #expect(attached.panelID == loading.id)
            #expect(second.panels.values.first is RemoteLoadingPanel)

            // An explicit later mirror has its own UUID, even for the same terminal.
            catalog.bindRemoteWorkspace(localWorkspaceID: second.id, machine: provider.machine, remoteWorkspaceID: nil)
            let later = try await open(second, provider: provider, catalog: catalog)
            #expect(later.workspaceID != attached.workspaceID && later.panelID != attached.panelID)
            #expect(first.panels.count == 1 && second.panels.count == 1)
            #expect(catalog.projections.count == 2)

            // An ordinary terminal can contain the user's first command; it is
            // never consumed as a loading card, regardless of a matching title.
            let ordinary = manager.addWorkspace(title: "Cloud VM", titleSource: .auto, initialTerminalCommand: "echo first-command",
                select: false, eagerLoadTerminal: false)
            let command = try #require(ordinary.focusedTerminalPanel)
            catalog.bindRemoteWorkspace(localWorkspaceID: ordinary.id, machine: provider.machine, remoteWorkspaceID: nil)
            _ = try await open(ordinary, provider: provider, catalog: catalog)
            #expect(ordinary.panels[command.id] === command)
            #expect(command.surface.initialCommand?.contains("first-command") == true)
        }
    }

    @Test("Concurrent opens share one attachment within the reserved workspace")
    func concurrentOpen() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            catalog.bindRemoteWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = RemoteLinkFirstValue<Bool>(), release = RemoteLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let first = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            let started = RemoteLinkFirstValue<Bool>()
            let second = Task { started.resolve(true); return try await open(pending, provider: provider, catalog: catalog) }
            _ = await started.result
            #expect(provider.materializations == 1)
            release.resolve(true)
            let a = try await first.value, b = try await second.value
            #expect(a == b)
            #expect(pending.panels.count == 1)
        }
    }

    @Test("Placement rejection restores the creating card for retry")
    func placementFailureRestoresLoadingCard() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            provider.returnMismatchedPlacement = true
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            catalog.bindRemoteWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let originalID = try #require(pending.panels.values.first?.id)
            await #expect(throws: (any Error).self) { try await open(pending, provider: provider, catalog: catalog) }
            #expect(pending.panels.count == 1)
            #expect((pending.panels[originalID] as? RemoteLoadingPanel)?.hasFailed == true)
            #expect(catalog.projections.isEmpty)
            provider.returnMismatchedPlacement = false
            let retry = try await open(pending, provider: provider, catalog: catalog)
            #expect(retry.panelID == originalID)
            #expect(pending.panels[originalID] is TerminalPanel)
        }
    }

    private func makeCatalog(_ manager: TabManager) -> SurfaceCatalog {
        SurfaceCatalog(tuiWorkspaceRenameService: TuiWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        )))
    }

    @Test("Closing a pending workspace cannot adopt into another create")
    func closedDestinationRejectsLateAttachment() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let other = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            catalog.bindRemoteWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = RemoteLinkFirstValue<Bool>(), release = RemoteLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let attachment = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            app.manager.closeWorkspace(pending, recordHistory: false)
            release.resolve(true)
            await #expect(throws: (any Error).self) { try await attachment.value }
            #expect(other.panels.count == 1 && other.panels.values.first is RemoteLoadingPanel)
            #expect(other.remoteWorkspaceBinding == nil)
            #expect(catalog.projections.isEmpty)
        }
    }

    @Test("Cancelling a mixed-content workspace fences its delayed attachment", arguments: [false, true])
    func mixedContentCancellationRejectsLateAttachment(openAgain: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let other = app.manager.addWorkspace(initialSurface: .remoteLoading, select: false)
            let loadingID = try #require(pending.panels.values.first { $0 is RemoteLoadingPanel }?.id)
            let pane = try #require(pending.bonsplitController.allPaneIds.first)
            let command = try #require(pending.newTerminalSurface(inPane: pane, focus: false, initialCommand: "echo first-command", autoRefreshMetadata: false))
            catalog.bindRemoteWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = RemoteLinkFirstValue<Bool>(), release = RemoteLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let attachment = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            attachment.cancel()
            #expect(pending.discardTuiMachineLoadingPanel(panelID: loadingID, machineID: provider.machine.rawValue))
            pending.remoteWorkspaceBinding = nil
            #expect(pending.remoteWorkspaceBinding == nil)
            // A later explicit open has a different admission claim and must not
            // join the cancelled adoption or be discarded with its late result.
            provider.beforeMaterialization = nil
            let reopened = openAgain ? try await open(pending, provider: provider, catalog: catalog) : nil
            release.resolve(true)
            await #expect(throws: (any Error).self) { try await attachment.value }
            #expect(pending.panels.count == (openAgain ? 2 : 1) && pending.panels[command.id] === command)
            if let reopened { #expect(pending.panels[reopened.panelID] is TerminalPanel) }
            #expect(command.surface.initialCommand?.contains("first-command") == true)
            #expect(other.panels.count == 1 && other.panels.values.first is RemoteLoadingPanel)
            #expect(catalog.projections.count == (openAgain ? 1 : 0))
        }
    }

    private func open(_ workspace: Workspace, provider: CloudMachineWorkspaceTestProvider, catalog: SurfaceCatalog) async throws -> SurfaceProjection {
        let resource = try #require(catalog.snapshot.resources(on: provider.machine).first)
        return try await catalog.project(resource.id, into: .workspace(id: workspace.id, placement: .split),
            focus: false, reuseExisting: true, reuseInWorkspace: workspace.id, remoteView: resource.remoteViews?.first).projection
    }
}
