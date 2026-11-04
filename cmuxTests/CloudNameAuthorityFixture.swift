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
final class CloudNameAuthorityFixture {
    let catalog: SurfaceCatalog
    let manager: TabManager
    let workspace: Workspace
    let provider: CloudNameAuthorityTestProvider
    let panelID: UUID
    let renameService: TuiWorkspaceRenameService

    init() throws {
        catalog = SurfaceCatalog.shared
        manager = TabManager()
        workspace = try #require(manager.selectedWorkspace)
        panelID = try #require(workspace.focusedPanelId)
        let owner = manager
        renameService = TuiWorkspaceRenameService(environment: .init(
            workspace: { owner.workspacesById[$0] }, tabManager: { _ in owner }, workspaces: { owner.tabs }
        ))
        provider = try CloudNameAuthorityTestProvider(destination: "names-\(UUID()).example.test",
                                                    catalog: catalog, renameService: renameService)
        catalog.register(provider)
        #expect(provider.install(provider.graph))
        workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: provider.machine.rawValue, remoteWorkspaceID: "a")
        catalog.record(SurfaceProjection(resource: .init(machine: provider.machine, kind: .terminal, key: "term_a"),
            workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "a", remoteTabID: "tab_a"))
        _ = provider.install(provider.graph)
        TerminalController.shared.setActiveTabManager(manager)
    }

    func close() async {
        await provider.receiver.stop()
        TerminalController.shared.setActiveTabManager(nil)
        catalog.endProjections(panelID: panelID, reason: .replaced)
        catalog.unregister(machine: provider.machine)
        for panel in workspace.panels.values { panel.close() }
        manager.tabs = []
    }

    func settle() async throws { try await catalog.tuiRenameCoordinator.waitForPendingRenames(on: provider.machine) }

    func call(_ method: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
        var params: [String: Any] = ["workspace_id": workspace.id.uuidString, "panel_id": panelID.uuidString]
        params.merge(extra) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: ["id": "fixture", "method": method, "params": params])
        let line = try #require(String(data: bytes, encoding: .utf8))
        let response = try #require(await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(line))
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        return try #require(object["result"] as? [String: Any])
    }

    func agentName(_ name: String, context: TuiAgentNameContext? = nil) async throws {
        let captured = context ?? catalog.tuiAgentNameContext(workspaceID: workspace.id, panelID: panelID)
        _ = try await call("surface.sync_codex_native_title", extra: [
            "title": name, "tui_name_context": (captured?.wire as Any?) ?? NSNull()
        ])
        try await settle()
    }

    func expectParity(_ name: String, workspaceName: String? = nil,
                      sidebarName: String? = nil, sidebarWorkspaceName: String? = nil) throws {
        let native = try #require(workspace.surfaceIdFromPanelId(panelID))
        #expect(workspace.bonsplitController.tab(native)?.title == name)
        let resource = try #require(catalog.snapshot.resources.first { $0.id.machine == provider.machine && $0.id.key == "term_a" })
        let view = try #require(resource.remoteViews?.first { $0.tabID == "tab_a" })
        #expect((view.name ?? resource.tuiProcessDisplayTitle) == (sidebarName ?? name))
        if let workspaceName {
            #expect(workspace.title == workspaceName)
            #expect(catalog.snapshot.machines.first { $0.id == provider.machine }?.remoteWorkspaces?.first { $0.id == "a" }?.name == (sidebarWorkspaceName ?? workspaceName))
        }
    }
}
