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
@Suite("Cloud stale inventory admission", .serialized, .exclusiveAppContext)
struct CloudStaleInventoryMaterializationTests {
    @Test("a stale graph never materializes an interactive restored terminal")
    func staleGraphIsNotInteractive() {
        #expect(CmuxTuiSurfaceProvider.shouldShowRecoverableTuiFailure(observation: .stale(reason: "link timeout")))
        #expect(!CmuxTuiSurfaceProvider.shouldShowRecoverableTuiFailure(observation: .current))
    }

    @Test("missing and stale observations fail the actual attachment and fresh state retries it", arguments: [false, true])
    func restoredAttachmentRecovers(hasStaleObservation: Bool) throws {
        _ = try #require(AppDelegate.shared)
        let manager = TabManager(createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        defer { workspace.teardownAllPanels(); manager.tabs = [] }
        try LiveWorkspaceFixture.withAppRegistration(of: manager) {
            let panelID = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog()
            let host = TuiTestHost(destination: "stale-\(UUID()).example.test")
            let provider = CmuxTuiSurfaceProvider(summary: host.summary, links: host.links(), catalog: catalog)
            catalog.register(provider)
            defer { provider.retireTransport(); catalog.unregister(machine: provider.machine) }
            let resource = SurfaceResource(id: .init(machine: provider.machine, kind: .terminal, key: "term_fixture"), title: "Terminal", lifecycle: .running)
            let state = TuiState(machine: provider.machine, cursor: nil, rawSnapshot: Data("{}".utf8),
                workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [], agents: [])
            if hasStaleObservation {
                catalog.replaceTuiState(state, resources: [resource], info: provider.info, observation: .stale(reason: "link timeout"))
            }
            let reservation = TuiTerminalPaneReservation(workspaceID: workspace.id, panelID: panelID, machine: provider.machine)
            workspace.tuiPendingCreations[panelID] = reservation
            defer { reservation.cancel?(); workspace.tuiPendingCreations[panelID] = nil }
            provider.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: nil)
            #expect(workspace.tuiMaterializationFailures[panelID] != nil)
            #expect(!provider.materializedPanels.contains(panelID))
            #expect(provider.restoredAttachTasks[panelID] == nil)
            #expect(workspace.retryReservedTuiTerminalPane(surfaceId: panelID))
            #expect(!provider.materializedPanels.contains(panelID))

            catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID))
            catalog.replaceTuiState(state, resources: [resource], info: provider.info, observation: .current)
            provider.projectionsRestored()
            #expect(provider.materializedPanels.contains(panelID))
            #expect(provider.restoredAttachTasks[panelID] != nil)
        }
    }

}
