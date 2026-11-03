import CmuxRemoteSession
import CmuxTui
import CmuxSurfaceCatalogModel
import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for a cloud port from discovery through the tree and the
/// shared sidebar/socket projection path.
@MainActor
@Suite("Cloud VM port discovery and opening")
struct CloudPortOpenRegressionTests {
    private let machine = SurfaceMachineID.ssh("65fa04ea0cd5435972d702f0dec4a23cc6cbb538c9887a1dc94bb2d88e46c905")
    private let workspace = SurfaceRemoteWorkspace(id: "ws_app", name: "app", index: 0, focused: true)
    @MainActor
    private final class FakeProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        let supportsPortPreviews: Bool
        var materialized: [(resource: SurfaceResourceID, destination: SurfaceDestination)] = []
        var refreshCalls = 0
        var forcedRefreshCalls = 0
        init(machine: SurfaceMachineID, supportsPortPreviews: Bool) {
            self.machine = machine
            self.supportsPortPreviews = supportsPortPreviews
            info = SurfaceMachineInfo(
                id: machine,
                name: machine.rawValue,
                status: "running",
                image: "cmux-devbox",
                
                memoryMb: nil,
                diskMb: nil,
                linkState: .connected,
                linkError: nil,
                cpuPercent: nil,
                memoryUsedMb: nil,
                diskUsedMb: nil,
                remoteWorkspaces: [],
                privateAddress: "10.0.0.7"
            )
        }
        func refresh() async {
            refreshCalls += 1
        }
        func refresh(force: Bool) async {
            refreshCalls += 1
            if force { forcedRefreshCalls += 1 }
        }
        func materialize(
            _ resource: SurfaceResource,
            at destination: SurfaceDestination,
            focus: Bool
        ) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination))
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }
        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new"),
                title: name ?? "shell",
                detail: cwd,
                lifecycle: .launching,
                agent: nil,
                remoteWorkspace: nil,
                port: nil,
                url: nil
            )
        }
        func projectionDidEnd(_ projection: SurfaceProjection) {}
    }
    private func machineInfo(workspaces: [SurfaceRemoteWorkspace] = []) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine,
            name: machine.rawValue,
            status: "running",
            image: "cmux-devbox",
            
            memoryMb: nil,
            diskMb: nil,
            linkState: .connected,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil,
            remoteWorkspaces: workspaces,
            privateAddress: "10.0.0.7"
        )
    }
    private func terminal() -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_app"),
            title: "server",
            detail: "/root/app",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            port: nil,
            url: nil
        )
        resource.remoteViews = [SurfaceRemoteView(tabID: "tab_app", workspace: workspace)]
        return resource
    }

    private func discoveredPort(_ number: Int, in workspace: SurfaceRemoteWorkspace? = nil) -> SurfaceResource {
        var resource = CmuxTuiSnapshotParser.portBrowser(
            machine: machine,
            port: number,
            directURL: "http://10.0.0.7:\(number)"
        )
        resource.remoteWorkspace = workspace
        resource.remoteViews = workspace.map { [SurfaceRemoteView(tabID: "tab_port_\(number)", workspace: $0)] }
        return resource
    }

    @Test("A discovered port has one stable machine identity in Ports and its cloud workspace")
    func discoveredPortIsGroupedAndRetainedByIdentity() throws {
        let port = discoveredPort(8000, in: workspace)
        let second = discoveredPort(3000)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [machineInfo(workspaces: [workspace])],
            resources: [port, second, terminal()],
            projections: []
        )
        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: machine, supportsPortPreviews: true))
        catalog.replaceResources(snapshot.resources, on: machine, info: machineInfo(workspaces: [workspace]))
        let members = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspace.id)
        #expect(Set(members.resources) == Set([terminal().id, port.id]))
        #expect(members.placements.first { $0.resource == port.id }?.remoteTabID == "tab_port_8000")
        #expect(snapshot.resources(on: machine).filter { $0.id.isForwardedPort }.map(\.id) == [port.id, second.id])
        #expect(SurfaceResourceID(machine: machine, kind: .browser, key: "port:08000").forwardedPort == nil)

        // An authoritative empty snapshot removes the row; it cannot leave a
        // stale port attached to the next machine/workspace rebuild.
        catalog.replaceResources([], on: machine, info: machineInfo(workspaces: [workspace]))
        #expect(catalog.snapshot.resources.isEmpty)
        #expect(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspace.id).resources.isEmpty)
    }

    @Test("A localhost browser view is folded into the canonical port in its cloud workspace")
    func snapshotBrowserPortKeepsWorkspaceMembership() throws {
        let snapshot: [String: Any] = [
            "workspaces": [[
                "id": workspace.id,
                "name": workspace.name,
                "index": workspace.index,
                "focused": workspace.focused,
            ]],
            "screens": [["id": "screen_app", "workspace_id": workspace.id]],
            "panes": [["id": "pane_app", "screen_id": "screen_app"]],
            "tabs": [["id": "tab_port", "pane_id": "pane_app"]],
            "terminals": [],
            "browsers": [[
                "id": "browser_http_tab",
                "tab_id": "tab_port",
                "url": "http://localhost:8000/health",
                "title": "API health",
                "status": "running",
            ]],
        ]
        let parsed = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: machine)
        #expect(parsed.count == 1)
        #expect(parsed.first?.id.key == "browser_http_tab")
        #expect(parsed.first?.port == 8000)
        #expect(parsed.first?.remoteWorkspaces.map(\.id) == [workspace.id])

        let merged = CmuxTuiSurfaceProvider.mergeSnapshotResources(
            pool: [CmuxTuiSnapshotParser.portBrowser(
                machine: machine,
                port: 8000,
                directURL: "http://10.0.0.7:8000"
            )],
            parsed: parsed,
            privateAddress: "10.0.0.7"
        )
        let port = try #require(merged.first { $0.id.isForwardedPort })
        #expect(port.id.key == "port:8000")
        #expect(port.title == "API health", "the workspace pointer keeps the daemon browser title")
        #expect(port.remoteWorkspaces.map(\.id) == [workspace.id])
        #expect(port.remoteViews?.map(\.tabID) == ["tab_port"])
        #expect(merged.contains { $0.id.key == "browser_http_tab" } == false)

        let loopbackOnly = CmuxTuiSurfaceProvider.mergeSnapshotResources(
            pool: [],
            parsed: parsed,
            privateAddress: "10.0.0.7"
        )
        #expect(loopbackOnly.contains { $0.id.key == "browser_http_tab" })
        #expect(loopbackOnly.contains { $0.id.isForwardedPort } == false)

        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: machine, supportsPortPreviews: true))
        catalog.replaceResources(merged, on: machine, info: machineInfo(workspaces: [workspace]))
        let members = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspace.id)
        #expect(members.resources == [port.id])
        #expect(members.placements.map(\.remoteTabID) == ["tab_port"])

        // A complete snapshot with no browser view retires the old workspace
        // membership but keeps the listening port in the machine pool.
        let cleared = CmuxTuiSurfaceProvider.mergeSnapshotResources(
            pool: [port],
            parsed: [],
            privateAddress: "10.0.0.7"
        )
        let clearedPort = try #require(cleared.first { $0.id == port.id })
        #expect(clearedPort.remoteWorkspaces.isEmpty)
        #expect(clearedPort.remoteViews == nil)
    }

    @Test("Duplicate daemon views merge once and preserve canonical tab order")
    func duplicatePortViewsAreDeduplicated() throws {
        let first = discoveredPort(8000, in: workspace)
        var second = discoveredPort(8000, in: workspace)
        second.remoteViews = [
            SurfaceRemoteView(tabID: "tab_port_8000", workspace: workspace),
            SurfaceRemoteView(tabID: "tab_port_second", workspace: workspace),
        ]
        let merged = CmuxTuiSurfaceProvider.mergeSnapshotResources(
            pool: [first],
            parsed: [first, second],
            privateAddress: "10.0.0.7"
        )
        let port = try #require(merged.first { $0.id.isForwardedPort })
        #expect(port.remoteViews?.map(\.tabID) == ["tab_port_8000", "tab_port_second"])
    }

    @Test("SSH and daemon transport listeners are not advertised as web previews")
    func infrastructureListenersAreNotWebPorts() {
        let bindings = """
        State Recv-Q Send-Q Local Address:Port Peer Address:Port
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
        LISTEN 0 128 [::]:22 [::]:*
        LISTEN 0 128 0.0.0.0:1337 0.0.0.0:*
        LISTEN 0 128 127.0.0.1:5901 0.0.0.0:*
        LISTEN 0 128 0.0.0.0:6901 0.0.0.0:*
        LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*
        """
        #expect(CmuxTuiSurfaceProvider.ports(from: bindings) == [3000, 5901, 6901])
    }

    @Test("Loopback services remain discoverable independently of private-address metadata")
    func loopbackDiscoveryIsIndependentOfAddress() {
        let listing = "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 127.0.0.1:8000 0.0.0.0:*\n"
        #expect(CmuxTuiSurfaceProvider.ports(from: listing) == [8000])
    }

    @Test("Unavailable scans retain ports while an authoritative empty scan retires them")
    func portScanCompletenessControlsRefresh() throws {
        #expect(CmuxTuiSurfaceProvider.ports(from: "ss unavailable") == nil)
        #expect(CmuxTuiSurfaceProvider.ports(from: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n") == [])
        let bindings = """
        State Recv-Q Send-Q Local Address:Port Peer Address:Port
        LISTEN 0 128 127.0.0.1:8000 0.0.0.0:*
        LISTEN 0 128 0.0.0.0:9000 0.0.0.0:*
        LISTEN 0 128 [::1]:9100 [::]:*
        """
        #expect(CmuxTuiSurfaceProvider.ports(from: bindings) == [8000, 9000, 9100])
        #expect(CmuxTuiSurfaceProvider.ports(from:
            "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 [::ffff:127.0.0.1]:9200 [::]:*\n"
        ) == [9200], "the SSH browser proxy opens the service on host loopback")
        let previous = [discoveredPort(8000, in: workspace)]
        let retained = CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: nil,
            previousResources: previous,
            privateAddress: "10.0.0.7"
        )
        #expect(retained.map(\.id) == [previous[0].id])
        #expect(retained.first?.url == "http://10.0.0.7:8000")
        let staleSSH = discoveredPort(22)
        let retainedWithStaleSSH = CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: nil,
            previousResources: [staleSSH, previous[0]],
            privateAddress: "10.0.0.7"
        )
        #expect(retainedWithStaleSSH.map(\.id) == [previous[0].id], "an unavailable refresh must not resurrect a cached SSH listener")
        #expect(CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: [],
            previousResources: previous,
            privateAddress: "10.0.0.7"
        ).isEmpty)
        let refreshed = CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: [9000, 8000, 9000],
            previousResources: previous,
            privateAddress: "10.0.0.8"
        )
        #expect(refreshed.map(\.id.key) == ["port:8000", "port:9000"])
        #expect(refreshed.first?.url == "http://10.0.0.8:8000")
        #expect(refreshed.first?.remoteWorkspace == workspace, "refresh keeps the owning workspace metadata")
        var inconsistent = discoveredPort(8000)
        inconsistent.port = 9000
        #expect(CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: [8000],
            previousResources: [inconsistent],
            privateAddress: "10.0.0.7"
        ).first?.port == 8000, "the canonical id owns the port number")
        #expect(CmuxTuiSurfaceProvider.portResources(
            machine: machine,
            scannedPorts: [8000],
            previousResources: refreshed,
            privateAddress: nil
        ).first?.url == nil, "an address withdrawal cannot leave a stale browser URL")
    }

    @Test("Port discovery uses the private cmux-tui link")
    func portDiscoveryUsesPrivateMachineLink() throws {
        let arguments = try #require(
            TuiCommandLine.listeningPortsArguments(socketPath: "/tmp/cmux-cloud.sock")
        )
        #expect(arguments == [
            "--socket", "/tmp/cmux-cloud.sock",
            "--json", "raw", "command",
            "--request-json", #"{"cmd":"machine-listening-tcp","id":1}"#,
        ])
    }

    @Test("Sidebar and repeated opens use the machine-owned local workspace and one catalog identity")
    func rowOpenUsesSharedCatalogPath() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: machine, supportsPortPreviews: true)
        catalog.register(provider)
        let port = discoveredPort(8000, in: workspace)
        catalog.replaceResources([terminal(), port], on: machine, info: machineInfo(workspaces: [workspace]))

        let ownerWorkspaceID = live.id()
        let unrelatedWorkspaceID = live.id()
        _ = try await catalog.project(
            terminal().id,
            into: .workspace(id: ownerWorkspaceID, placement: .split),
            focus: false,
            reuseExisting: false
        )

        let destination = try #require(catalog.preferredLocalWorkspaceID(for: port, fallback: unrelatedWorkspaceID))
        _ = try await catalog.openTuiPort(machine: machine, port: 8000,
            into: .workspace(id: destination, placement: .split), focus: true)

        #expect(provider.materialized.last?.resource == port.id)
        #expect(provider.materialized.last?.destination == .workspace(id: ownerWorkspaceID, placement: .split))

        // A refresh can retire the row between click and materialization while the
        // pane projection is still live. The owner vote remains anchored by the
        // canonical resource id instead of falling back to the selected workspace.
        catalog.remove(port.id)
        #expect(catalog.preferredLocalWorkspaceID(for: port.id, fallback: unrelatedWorkspaceID) == ownerWorkspaceID)

        let second = try await catalog.openTuiPort(
            machine: machine,
            port: 8000,
            into: .workspace(id: unrelatedWorkspaceID, placement: .split),
            focus: false,
            reuseExisting: true
        )
        #expect(second.reused)
        #expect(provider.materialized.count == 2, "the first explicit terminal projection is separate; the port itself is opened once")
        #expect(catalog.projections(of: port.id).count == 1)

        // A scoped sidebar open must not reuse the owner's pane when the caller
        // explicitly asks for another local workspace.
        let scoped = try await catalog.openTuiPort(
            machine: machine,
            port: 8000,
            into: .workspace(id: unrelatedWorkspaceID, placement: .split),
            focus: false,
            reuseExisting: true,
            reuseInWorkspace: unrelatedWorkspaceID
        )
        #expect(!scoped.reused)
        #expect(catalog.projections(of: port.id).count == 2)

        // A pool-only port has no remote workspace owner; unrelated machine
        // projections must not override the caller's selected workspace.
        let poolPort = discoveredPort(9000)
        catalog.upsert(poolPort)
        #expect(catalog.preferredLocalWorkspaceID(for: poolPort, fallback: unrelatedWorkspaceID) == unrelatedWorkspaceID)

        // A just-opened port must survive a provider snapshot that was captured
        // before the upsert, even when its projection has not been recorded yet.
        let captured = catalog.snapshot.resources(on: machine).filter { $0.id != poolPort.id }
        let concurrent = catalog.preservingConcurrentPortResources(
            captured,
            on: machine,
            since: captured
        )
        #expect(concurrent.contains { $0.id == poolPort.id })
    }

    @Test("Unsupported providers fail before a synthetic row or browser pane is created")
    func unsupportedProviderFailsClosed() async {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let destination = live.id()
        let provider = FakeProvider(machine: machine, supportsPortPreviews: false)
        catalog.register(provider)

        await #expect(throws: SurfaceCatalogError.unsupported(
            SurfaceCatalog.portPreviewUnavailableMessage(machineID: machine.rawValue)
        )) {
            try await catalog.openTuiPort(
                machine: machine,
                port: 8000,
                into: .workspace(id: destination, placement: .split),
                focus: false,
                reuseExisting: false
            )
        }
        #expect(provider.materialized.isEmpty)
        #expect(catalog.snapshot.resources.isEmpty)
    }

    @Test("Machine-scoped refresh does not wait on another cloud provider")
    func scopedRefreshOnlyTouchesRequestedMachine() async {
        let catalog = SurfaceCatalog()
        let otherMachine = SurfaceMachineID.ssh("39b2b053cd653579199fcbcaba118329c155313886f14cc1d365602ad984875c")
        let target = FakeProvider(machine: machine, supportsPortPreviews: true)
        let other = FakeProvider(machine: otherMachine, supportsPortPreviews: true)
        catalog.register(target)
        catalog.register(other)

        await catalog.refresh(machine: machine, force: true)

        #expect(target.forcedRefreshCalls == 1)
        #expect(other.refreshCalls == 0)
    }

    @Test("Unsupported endpoint placeholders do not instruct a permanent retry")
    func unsupportedPlaceholderIsNonRetryable() {
        let html = SurfaceBrowserPlaceholder.failed(
            "ssh-host:8000",
            error: "This provider cannot open port previews.",
            retryable: false
        )
        #expect(html.contains("Connect to the SSH host directly"))
        #expect(!html.contains("open it again from the sidebar"))
    }
}
