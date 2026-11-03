import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the SSH daemon graph and the catalog's exact workspace placements.
@MainActor
@Suite
struct CloudWorkspaceMembershipTests {
    private let machine = SurfaceMachineID.ssh("f9061274042397d0b8c50fa336f22d4e60ff85bce2b765476875c7ac23e96b9f")

    @Test("Terminal and browser workspaces contain only their accepted daemon tabs")
    func terminalOnlyCreation() throws {
        let catalog = SurfaceCatalog()
        let initial = try state()
        publish(initial, to: catalog)
        try expectMembership(initial, in: catalog)
        #expect(Set(catalog.snapshot.resources(on: machine).map(\.kind)) == Set([.terminal, .browser]))

        // A newly created workspace comes from the next complete daemon graph.
        var document = try #require(initial.snapshotObject())
        document["workspaces"] = (document["workspaces"] as? [[String: Any]] ?? []) + [
            ["id": "ws_new", "name": "workspace-3", "index": 2]
        ]
        document["screens"] = (document["screens"] as? [[String: Any]] ?? []) + [
            ["id": "screen_new", "workspace_id": "ws_new"]
        ]
        document["panes"] = (document["panes"] as? [[String: Any]] ?? []) + [
            ["id": "pane_new", "screen_id": "screen_new"]
        ]
        document["tabs"] = (document["tabs"] as? [[String: Any]] ?? []) + [
            ["id": "tab_new", "pane_id": "pane_new", "content_kind": "terminal", "content_id": "term_new"]
        ]
        document["terminals"] = (document["terminals"] as? [[String: Any]] ?? []) + [
            ["id": "term_new", "tab_id": "tab_new", "title": "terminal", "lifecycle": "running"]
        ]
        document["cursor"] = ["generation": "membership", "revision": "2"]
        let created = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        publish(created, to: catalog)
        try expectMembership(created, in: catalog)
        let detached = try removing("tab_new", from: created)
        publish(detached, to: catalog, delta: true)
        try expectMembership(detached, in: catalog)
        #expect(catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new")]?.remoteViews?.isEmpty == true)
    }


    @Test("An explicit empty view list overrides stale legacy workspace metadata")
    func detachedBrowserDoesNotUseLegacyWorkspace() throws {
        let catalog = SurfaceCatalog()
        let current = try state()
        var resources = resources(current)
        let index = try #require(resources.firstIndex { $0.kind == .browser })
        let browserID = resources[index].id
        resources[index].remoteViews = []
        resources[index].remoteWorkspace = info(current).remoteWorkspaces?.first
        catalog.replaceTuiState(current, resources: resources, info: info(current))
        let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_a")
        #expect(!group.resources.contains(browserID))
        #expect(catalog.resources[browserID] != nil)
    }


    private func state(
        generation: String = "membership", focused: String = "a"
    ) throws -> TuiState {
        let workspaceIDs = ["a", "b"]
        var tabs: [[String: Any]] = workspaceIDs.map {
            ["id": "tab_\($0)", "pane_id": "pane_\($0)", "content_kind": "terminal", "content_id": "term_\($0)", "index": 0]
        }
        tabs.append(["id": "tab_docs", "pane_id": "pane_a", "content_kind": "browser", "content_id": "docs", "index": 1])
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": "1"],
            "workspaces": workspaceIDs.enumerated().map {
                ["id": "ws_\($0.element)", "name": "workspace-\($0.offset + 1)", "index": $0.offset, "focused": $0.element == focused] as [String: Any]
            },
            "screens": workspaceIDs.map { ["id": "screen_\($0)", "workspace_id": "ws_\($0)"] },
            "panes": workspaceIDs.map { ["id": "pane_\($0)", "screen_id": "screen_\($0)"] },
            "tabs": tabs,
            "terminals": workspaceIDs.map {
                ["id": "term_\($0)", "tab_id": "tab_\($0)", "title": "terminal", "lifecycle": "running"]
            },
            "browsers": [["id": "docs", "tab_id": "tab_docs", "title": "Docs", "url": "http://localhost:3000"]],
            "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func removing(_ tabID: String, from state: TuiState) throws -> TuiState {
        let previous = try #require(state.cursor)
        let cursor = TuiCursor(generation: previous.generation, revision: previous.revision + 1)
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": String(previous.revision), "revision": String(cursor.revision),
            "changes": [["kind": "delete", "resource": "tab", "id": tabID]]
        ]
        return try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: JSONSerialization.data(withJSONObject: delta), cursor: cursor, to: state
        ))
    }

    private func info(_ state: TuiState) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "Membership test", status: "running", image: nil, 
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
    }

    private func resources(_ state: TuiState) -> [SurfaceResource] {
        CmuxTuiSnapshotParser.resources(from: state)
    }

    private func publish(_ state: TuiState, to catalog: SurfaceCatalog, delta: Bool = false) {
        if delta {
            catalog.applyTuiStateDelta(state, resources: resources(state), info: info(state))
        } else {
            catalog.replaceTuiState(state, resources: resources(state), info: info(state))
        }
    }

    private func expectMembership(_ state: TuiState, in catalog: SurfaceCatalog) throws {
        for workspace in state.workspaces {
            let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspace.id)
            let screens = Set(state.screens.filter { $0.workspaceID == workspace.id }.map(\.id))
            let panes = Set(state.panes.filter { screens.contains($0.screenID) }.map(\.id))
            let actualTabs = state.tabs.filter { panes.contains($0.paneID) }
            #expect(group.placements.count == actualTabs.count, "\(workspace.id) placements must equal real layout tabs")
            #expect(Set(group.placements.compactMap(\.remoteTabID)) == Set(actualTabs.map(\.id)))
        }
    }

}
