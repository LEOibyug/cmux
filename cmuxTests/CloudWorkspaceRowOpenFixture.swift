import AppKit
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
final class CloudWorkspaceRowOpenFixture {
    let base: TuiWorkspaceCreationSidebarFixture
    let provider: CloudWorkspaceRowOpenProvider
    typealias OpenResult = (workspaceID: UUID, projections: [SurfaceProjection])
    private var opening: Task<OpenResult, Error>?
    let remote = SurfaceRemoteWorkspace(id: "ws-open", name: "Existing", index: 0, focused: true)

    init() throws {
        base = try TuiWorkspaceCreationSidebarFixture()
        base.manager.window = nil
        base.catalog.unregister(machine: base.provider.machine)
        provider = CloudWorkspaceRowOpenProvider(machine: base.provider.machine)
        base.catalog.register(provider)
        try publish()
    }

    func publish(includeWorkspace: Bool = true, generation: String = "open", revision: Int = 1) throws {
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": includeWorkspace ? [["id": remote.id, "name": remote.name]] : [],
            "screens": [["id": "screen", "workspace_id": remote.id, "layout": ["root": [
                "kind": "split", "direction": "horizontal", "ratio": 0.6,
                "first": ["kind": "leaf", "pane_id": "one", "tab_ids": ["tab-one"]],
                "second": ["kind": "leaf", "pane_id": "two", "tab_ids": ["tab-two"]]
            ]]]],
            "panes": [["id": "one", "screen_id": "screen"], ["id": "two", "screen_id": "screen"]],
            "tabs": [["id": "tab-one", "pane_id": "one", "content_kind": "terminal", "content_id": "term-one"],
                     ["id": "tab-two", "pane_id": "two", "content_kind": "terminal", "content_id": "term-two"]],
            "terminals": [["id": "term-one", "lifecycle": "running"], ["id": "term-two", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: provider.machine))
        var info = provider.info
        info.remoteWorkspaces = includeWorkspace ? [remote] : []
        base.catalog.replaceTuiState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        base.catalog.reconcileTuiRemoteState(machine: provider.machine, state: state)
    }

    func group() throws -> SurfaceResourceGroup {
        try base.catalog.remoteWorkspaceGroup(machine: provider.machine, workspaceID: remote.id)
    }

    func activate(group: SurfaceResourceGroup? = nil) throws {
        let captured = try group ?? self.group()
        opening = Task { @MainActor [base, provider, remote] in
            try await base.catalog.tuiWorkspaceCreationCoordinator.openExistingWorkspace(
                provider: provider, workspace: remote, group: captured,
                focus: true, host: TuiWorkspaceCreationHost(manager: base.manager)
            )
        }
    }

    func waitForOpen() async throws {
        let task = try #require(opening)
        _ = try await task.value
    }

    func close() {
        provider.gate?.resolve(true)
        opening?.cancel()
        base.catalog.tuiWorkspaceCreationCoordinator.cancelAll()
        base.close()
    }
}
