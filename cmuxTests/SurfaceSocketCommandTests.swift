import CmuxRemoteSession
import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises retained surface socket requests against a user-controlled SSH host
/// identity and a recording provider, without starting a remote connection.
@MainActor
@Suite(.serialized)
struct SurfaceSocketCommandTests {

    @Test func emptyWorkspaceHasARetryableSocketCode() async throws {
        let response = await Task.detached {
            TerminalController.shared.v2ThrowingResultCall(id: "empty-workspace", timeoutSeconds: 5) {
                throw SurfaceCatalogError.nothingToOpen("workspace ws_pending")
            }
        }.value
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let error = try Self.error(object)
        #expect(error["code"] as? String == "not_ready")
    }


    @Test func providerErrorsPreserveResourceDetails() {
        let detail = UUID().uuidString
        let terminalFailure = CmuxTuiSurfaceProvider.ProviderError.terminalNotCreated(detail)
        #expect(terminalFailure.localizedDescription.contains(detail))

        let workspaceID = UUID().uuidString
        let workspaceFailure = CmuxTuiSurfaceProvider.ProviderError.remoteWorkspaceNotFound(workspaceID)
        #expect(workspaceFailure.localizedDescription.contains(workspaceID))
    }


    /// Records requests for resources belonging to a user-controlled SSH host.
    final class RecordingSSHProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        unowned let catalog: SurfaceCatalog
        var materialized: [(resource: SurfaceResourceID, destination: SurfaceDestination, focus: Bool)] = []
        var createdTerminals: [(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?)] = []
        var refreshes = 0

        init(machine: SurfaceMachineID, catalog: SurfaceCatalog, workspaces: [SurfaceRemoteWorkspace]) {
            self.machine = machine
            self.catalog = catalog
            info = SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: nil,
                memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces
            )
        }

        func refresh() async { refreshes += 1 }

        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination, focus))
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }

        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            createdTerminals.append((command, cwd, name, remoteWorkspaceID))
            let workspace = (info.remoteWorkspaces ?? []).first { $0.id == remoteWorkspaceID } ?? info.remoteWorkspaces?.first
            let resource = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new_\(createdTerminals.count)"),
                title: name ?? "", detail: cwd, lifecycle: .launching, agent: nil,
                remoteWorkspace: workspace, port: nil, url: nil
            )
            // Like the real provider: the terminal exists in the catalog before it is projected.
            catalog.upsert(resource)
            return resource
        }

        func projectionDidEnd(_ projection: SurfaceProjection) {}

    }

    /// One SSH host with two populated workspaces and one empty workspace.
    struct Fixture {
        let machineID: String
        let machine: SurfaceMachineID
        let provider: RecordingSSHProvider
        let manager: TabManager
        let workspaceID: UUID
        static let wsA = SurfaceRemoteWorkspace(id: "ws_a", name: "alpha", index: 0, focused: true)
        static let wsB = SurfaceRemoteWorkspace(id: "ws_b", name: "beta", index: 1, focused: false)
        static let wsEmpty = SurfaceRemoteWorkspace(id: "ws_empty", name: "empty", index: 2, focused: false)

        var termA1: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a1") }
        var termA2: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a2") }
        var termB: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_b") }
        var browserA: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .browser, key: "browser_1") }

        @MainActor
        init(manager: TabManager) {
            // Locals first: a nested helper must not capture `self` before every stored
            // property is initialized.
            let host = TuiTestHost(destination: "socket-\(UUID().uuidString.lowercased()).example.test")
            let machine = host.machine
            let catalog = SurfaceCatalog.shared
            let provider = RecordingSSHProvider(machine: machine, catalog: catalog, workspaces: [Self.wsA, Self.wsB, Self.wsEmpty])
            catalog.register(provider)
            let terminal: (String, SurfaceRemoteWorkspace) -> SurfaceResource = { key, workspace in
                var resource = SurfaceResource(
                    id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: key, detail: "/root",
                    lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil
                )
                resource.remoteViews = [SurfaceRemoteView(tabID: "tab_\(key)", workspace: workspace)]
                return resource
            }
            var browser = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .browser, key: "browser_1"), title: "docs", detail: "http://localhost:3000",
                lifecycle: .running, agent: nil, remoteWorkspace: Self.wsA, port: 3000, url: "http://localhost:3000"
            )
            browser.remoteViews = [SurfaceRemoteView(tabID: "tab_browser_1", workspace: Self.wsA)]
            catalog.replaceResources(
                [terminal("term_a1", Self.wsA), terminal("term_a2", Self.wsA), terminal("term_b", Self.wsB), browser],
                on: machine,
                info: provider.info
            )
            TerminalController.shared.setActiveTabManager(manager)
            self.machineID = machine.rawValue
            self.machine = machine
            self.provider = provider
            self.manager = manager
            self.workspaceID = manager.selectedWorkspace!.id
        }

        /// The pane belongs to this windowless fixture, so requests also name
        /// its workspace instead of asking the live-window router to find it.
        @MainActor
        var livePaneID: String? {
            // Straight from the workspace: the test TabManager is the controller's active
            // manager but is not registered with the app's window list.
            guard let workspace = manager.selectedWorkspace, let panel = workspace.focusedPanelId else { return nil }
            return workspace.paneId(forPanelId: panel)?.id.uuidString
        }

        @MainActor
        func tearDown() {
            TerminalController.shared.setActiveTabManager(nil)
            SurfaceCatalog.shared.unregister(machine: machine)
            manager.tabs.forEach { $0.teardownAllPanels() }

        }
    }

    static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let app = try VaultPaneAppFixture()
            // Keep app-owned routing deterministic for local and SSH surface requests.
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(app.windowID.uuidString)")
            app.appDelegate.mainWindowContexts.values.first { $0.windowId == app.windowID }?.window = window
            defer { withExtendedLifetime(window) {} }
            defer {
                app.tearDown()
                TerminalController.shared.setActiveTabManager(previousManager)
            }
            let fixture = Fixture(manager: app.manager)
            defer { fixture.tearDown() }
            try await body(fixture)
        }
    }

    // MARK: - transport

    /// Runs the surface socket-worker lane while allowing catalog work on the main actor.
    nonisolated static func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let response = TerminalController.shared.handleSocketLine(line)
                do {
                    let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
                    continuation.resume(returning: object ?? [:])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func ok(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == true, "expected success, got \(response)")
        return try #require(response["result"] as? [String: Any])
    }


    static func error(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == false, "expected an error, got \(response)")
        return try #require(response["error"] as? [String: Any])
    }

    private static func resourceIDs(_ result: [String: Any]) -> Set<String> {
        Set(((result["resources"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
    }

    // MARK: - surface.catalog

    @Test func catalogListsTheMachineAndItsResources() async throws {
        try await Self.withFixture { fixture in

            let all = try Self.ok(try await Self.call("surface.catalog", [:]))
            let machines = try #require(all["machines"] as? [[String: Any]])
            #expect(machines.contains { ($0["id"] as? String) == fixture.machineID })
            let ownMachine = try #require(machines.first { ($0["id"] as? String) == fixture.machineID })
            #expect((ownMachine["remote_workspaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["ws_a", "ws_b", "ws_empty"])
            #expect(Self.resourceIDs(all).isSuperset(of: [fixture.termA1.rawValue, fixture.termA2.rawValue, fixture.termB.rawValue, fixture.browserA.rawValue]))
            #expect(all["workspaces"] == nil)
            // A machine filter narrows every section of the catalog.
            let one = try Self.ok(try await Self.call("surface.catalog", ["machine": fixture.machineID]))
            #expect((one["machines"] as? [[String: Any]])?.count == 1)
            #expect(Self.resourceIDs(one) == [fixture.termA1.rawValue, fixture.termA2.rawValue, fixture.termB.rawValue, fixture.browserA.rawValue])
            #expect(one["workspaces"] == nil)


            // `refresh` re-syncs the provider.
            _ = try Self.ok(try await Self.call("surface.catalog", ["machine": fixture.machineID, "refresh": true]))
            #expect(fixture.provider.refreshes == 1)
        }
    }

    // MARK: - surface.project

    @Test func projectReusesFocusesAndHonorsPlacementFlags() async throws {
        try await Self.withFixture { fixture in
            let resource = fixture.termA1.rawValue

            let first = try Self.ok(try await Self.call("surface.project", ["resource": resource]))
            #expect(first["reused"] as? Bool == false)
            #expect(first["workspace_id"] as? String == fixture.workspaceID.uuidString, "no target → the selected workspace")
            #expect(fixture.provider.materialized.count == 1)
            #expect(fixture.provider.materialized[0].destination == .workspace(id: fixture.workspaceID, placement: .split))
            // A socket client that does not ask for focus opens in the background: an agent
            // must not pull the person away from what they are typing in.
            #expect(fixture.provider.materialized[0].focus == false)

            // The catalog reuses the pane already showing the resource…
            let again = try Self.ok(try await Self.call("surface.project", ["resource": resource]))
            #expect(again["reused"] as? Bool == true)
            #expect(again["surface_id"] as? String == first["surface_id"] as? String)
            #expect(fixture.provider.materialized.count == 1)

            // …unless `reuse: false` (`--new`): a second pane, at the pane edge the caller named
            // (a LIVE pane: the workspace's own focused pane).
            let pane = try #require(fixture.livePaneID)
            let split = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString,
                "pane_id": pane, "direction": "left", "focus": false,
            ]))
            #expect(split["reused"] as? Bool == false)
            #expect(fixture.provider.materialized.count == 2)
            #expect(fixture.provider.materialized[1].destination == .split(workspaceID: fixture.workspaceID, paneID: pane, direction: .left))
            #expect(fixture.provider.materialized[1].focus == false)

            // `placement: tab` on a pane becomes a tab destination.
            _ = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString,
                "pane_id": pane, "placement": "tab",
            ]))
            #expect(fixture.provider.materialized.last?.destination == .tab(workspaceID: fixture.workspaceID, paneID: pane, index: nil))
            #expect(fixture.provider.materialized.last?.focus == false)

            // An explicit `focus: true` (an interactive `cmux surface open`, or `--focus`) is honored.
            _ = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString, "focus": true,
            ]))
            #expect(fixture.provider.materialized.last?.focus == true)

            let projections = try Self.ok(try await Self.call("surface.catalog", ["machine": fixture.machineID]))["projections"] as? [[String: Any]]
            #expect(projections?.filter { ($0["resource"] as? String) == resource }.count == 4)
        }
    }

    @Test func projectRejectsUnknownSurfacesAndUnresolvableTargets() async throws {
        try await Self.withFixture { fixture in

            _ = try Self.error(try await Self.call("surface.project", ["resource": "\(fixture.machineID)/terminal/term_ghost"]))

            // An explicit workspace that resolves to nothing is an error, never a silent
            // fall-through to the selected workspace.
            let bogus = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, "workspace_id": "workspace:999999"]))
            #expect(bogus["code"] as? String == "invalid_params")
            #expect((bogus["message"] as? String)?.contains("workspace:999999") == true)
            let bogusPane = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, "pane_id": "pane:999999"]))
            #expect(bogusPane["code"] as? String == "invalid_params")
            // Well-formed but dead ids are just as unresolvable: a closed pane's UUID, a
            // workspace UUID nobody has, a surface UUID that is not a panel.
            for (key, value) in [("pane_id", UUID().uuidString), ("workspace_id", UUID().uuidString), ("surface_id", UUID().uuidString)] {
                let dead = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, key: value]))
                #expect(dead["code"] as? String == "invalid_params", "\(key) \(value) must not fall back to the selected workspace")
            }
            #expect(fixture.provider.materialized.isEmpty, "nothing opened anywhere")

            let malformed = try Self.error(try await Self.call("surface.project", ["resource": "not-a-resource"]))
            #expect(malformed["code"] as? String == "invalid_params")
        }
    }

    @Test func projectResolvesAnExplicitSurfaceInAnotherWindow() async throws {
        try await Self.withFixture { fixture in
            let app = try #require(AppDelegate.shared)
            // This test exercises ownership lookup, not window rendering.
            // Keep the second window context deterministic and avoid leaving
            // SwiftUI render/teardown work running into the next socket test.
            let manager = TabManager()
            let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
            }
            let workspace = try #require(manager.selectedWorkspace)
            let surfaceID = try #require(workspace.focusedPanelId)
            let paneID = try #require(workspace.paneId(forPanelId: surfaceID))
            TerminalController.shared.setActiveTabManager(fixture.manager)

            let result = try Self.ok(try await Self.call("surface.project", [
                "resource": fixture.termA1.rawValue,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "direction": "left",
                "focus": false,
            ]))

            #expect(result["workspace_id"] as? String == workspace.id.uuidString)
            #expect(fixture.provider.materialized.count == 1)
            #expect(fixture.provider.materialized[0].destination == .split(
                workspaceID: workspace.id, paneID: paneID.id.uuidString, direction: .left
            ))
            #expect(fixture.provider.materialized[0].focus == false)
        }
    }

    // MARK: - surface.new_terminal

    @Test func newTerminalPassesTheRecipeThroughAndOpensUnlessToldNotTo() async throws {
        try await Self.withFixture { fixture in

            let headless = try Self.ok(try await Self.call("surface.new_terminal", [
                "machine": fixture.machineID, "open": false, "command": ["bun", "test"], "cwd": "/root/app", "name": "tests", "remote_workspace_id": "ws_b",
            ]))
            try #require(fixture.provider.createdTerminals.count == 1)
            let created = fixture.provider.createdTerminals[0]
            #expect(created.command == ["bun", "test"])
            #expect(created.cwd == "/root/app")
            #expect(created.name == "tests")
            #expect(created.remoteWorkspaceID == "ws_b")
            #expect(headless["terminal_id"] as? String == "term_new_1")
            #expect(headless["resource"] as? String == "\(fixture.machineID)/terminal/term_new_1")
            #expect(headless["remote_workspace_id"] as? String == "ws_b")
            #expect(headless["surface_id"] == nil, "headless: no pane")
            #expect(fixture.provider.materialized.isEmpty)

            let opened = try Self.ok(try await Self.call("surface.new_terminal", ["machine": fixture.machineID]))
            #expect(fixture.provider.createdTerminals.count == 2)
            #expect(fixture.provider.createdTerminals[1].remoteWorkspaceID == nil, "the provider picks the workspace")
            #expect(opened["workspace_id"] as? String == fixture.workspaceID.uuidString)
            #expect((opened["surface_id"] as? String).flatMap(UUID.init(uuidString:)) != nil)
            #expect(fixture.provider.materialized.count == 1)
            #expect(fixture.provider.materialized[0].resource.key == "term_new_2")
            #expect(fixture.provider.materialized[0].focus == false, "no `focus` param: a background open")


            let missing = try Self.error(try await Self.call("surface.new_terminal", [:]))
            #expect(missing["code"] as? String == "invalid_params")
            let unresolvable = try Self.error(try await Self.call("surface.new_terminal", ["machine": fixture.machineID, "workspace_id": "workspace:999999"]))
            #expect(unresolvable["code"] as? String == "invalid_params")
            #expect(fixture.provider.createdTerminals.count == 2, "a bad target creates nothing")
        }
    }

    // MARK: - background opens

    @Test func backgroundOpenMarksThePaneUnreadUnlessThePersonIsLookingAtIt() async throws {
        try await Self.withFixture { fixture in
            let manager = fixture.manager
            let selected = try #require(manager.selectedWorkspace)
            let background = try #require(manager.addWorkspaceIfActive(select: false))
            defer { manager.closeWorkspace(background, recordHistory: false) }
            #expect(manager.selectedTabId == selected.id)
            let landed = try #require(background.focusedPanelId)
            #expect(!background.panelIsUnread(landed))

            SurfacePaneFactory.markOpenedInBackground(panelID: landed, in: background.id)
            #expect(background.panelIsUnread(landed), "something landed where the person is not looking")

            let onScreen = try #require(selected.focusedPanelId)
            SurfacePaneFactory.markOpenedInBackground(panelID: onScreen, in: selected.id)
            #expect(!selected.panelIsUnread(onScreen), "the pane the person is looking at is not news")
        }
    }

}
