import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud port discovery state")
struct TuiPortDiscoveryStateTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test("The authenticated browser route discovers loopback and wildcard services")
    func scanMatchesBrowserProxy() throws {
        let scan = try #require(CmuxTuiSurfaceProvider.portScan(from: VMExecResult(exitCode: 0, stdout: """
        LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*
        LISTEN 0 128 0.0.0.0:8000 0.0.0.0:*
        LISTEN 0 128 10.0.0.7:9000 0.0.0.0:*
        LISTEN 0 128 [::1]:9100 [::]:*
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
        """, stderr: ""), privateAddress: "10.0.0.7"))
        #expect(scan.ports == [3000, 8000])
        #expect(scan.loopbackOnlyPorts == [3000])
        #expect(scan.otherBindingPorts == [9000, 9100])
        #expect(scan.state == .available)
        let loopback = try #require(TuiPortScanResult(socketListing: "LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*"))
        #expect(loopback.state == .loopbackOnly)
    }

    @Test("An empty successful scan, other-interface listeners, and an invalid scan differ")
    func noServiceAndUnavailableAreDifferent() throws {
        #expect(TuiPortScanResult(socketListing: "")?.state == .empty(.noListeningService))
        #expect(TuiPortScanResult(socketListing: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n")?.ports == [])
        #expect(TuiPortScanResult(socketListing: "LISTEN 0 128 10.0.0.7:3000 0.0.0.0:*")?.state == .empty(.otherInterfaceOnly))
        #expect(TuiPortScanResult(socketListing: "inventory unavailable") == nil)
        // A diagnostic or UNCONN row beside real rows does not void the inventory.
        #expect(TuiPortScanResult(socketListing: "inventory unavailable\nLISTEN 0 128 127.0.0.1:3000 0.0.0.0:*")?.ports == [3000])
        #expect(TuiPortScanResult(socketListing: "UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*")?.state == .empty(.noListeningService))
        #expect(CmuxTuiSurfaceProvider.portScan(from: "ss unavailable") == nil)
    }

    @Test("System loopback aliases such as systemd-resolved's stub are not other-interface services")
    func loopbackAliasesAreIgnored() throws {
        let resolved = """
        LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*
        LISTEN 0 4096 127.0.0.54:53 0.0.0.0:*
        """
        let idle = try #require(TuiPortScanResult(socketListing: resolved))
        #expect(idle.otherBindingPorts == [])
        #expect(idle.state == .empty(.noListeningService))
        let zoned = try #require(TuiPortScanResult(socketListing: resolved + "\nLISTEN 0 128 127.0.0.1%lo:3000 0.0.0.0:*"))
        #expect(zoned.ports == [3000])
        #expect(zoned.state == .loopbackOnly)
    }

    @Test("No scan runs without demand; first demand publishes loading before a result")
    func demandAndCompletion() {
        var discovery = readyDiscovery()
        #expect(discovery.state == .notRequested && !discovery.mayScan)
        discovery.request()
        #expect(discovery.state == .loading && discovery.mayScan)
        let request = discovery.beginScan()
        let completed = discovery.complete(TuiPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        #expect(completed)
        #expect(discovery.state == .available)
        let failed = discovery.beginScan()
        let failedCompletion = discovery.complete(nil, request: failed, at: now, socketPath: "first")
        #expect(failedCompletion)
        #expect(discovery.state == .stale && discovery.scan?.ports == [3000])
        let retry = discovery.beginScan()
        let emptyCompletion = discovery.complete(TuiPortScanResult(ports: []), request: retry, at: now, socketPath: "first")
        #expect(emptyCompletion)
        #expect(discovery.state == .empty(.noListeningService) && discovery.scan?.ports == [])
    }

    @Test("A rescan keeps the settled inventory visible and survives a routine summary poll")
    func rescanKeepsSettledState() {
        var discovery = readyDiscovery()
        discovery.request()
        let first = discovery.beginScan()
        _ = discovery.complete(TuiPortScanResult(ports: [3000]), request: first, at: now, socketPath: "first")
        let rescan = discovery.beginScan()
        #expect(discovery.state == .available)
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.7")
        let completed = discovery.complete(TuiPortScanResult(ports: [3000, 8000]), request: rescan, at: now, socketPath: "first")
        #expect(completed)
        #expect(discovery.state == .available && discovery.scan?.ports == [3000, 8000])
    }

    @Test("A fresh cached scan settles a repeated request instead of leaving it loading")
    func cachedScanSettlesRequest() {
        var discovery = readyDiscovery()
        discovery.request()
        let request = discovery.beginScan()
        _ = discovery.complete(TuiPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        discovery.request()
        #expect(discovery.state == .loading)
        #expect(discovery.cachedScan(at: now.addingTimeInterval(5), socketPath: "first", force: false)?.ports == [3000])
        #expect(discovery.state == .available)
    }

    /// A refresh cancelled while another refresh's scan runs must leave that scan's loading state alone.
    @Test("Abandoning a request never hides a scan that is still running")
    func abandonKeepsRunningScan() {
        var discovery = readyDiscovery()
        discovery.request()
        let scan = discovery.beginScan()
        discovery.abandonRequest(discovery.request())
        #expect(discovery.state == .loading)
        let completed = discovery.complete(TuiPortScanResult(ports: [3000]), request: scan, at: now, socketPath: "first")
        #expect(completed)
        #expect(discovery.state == .available)
    }

    @Test("Capabilities and private-route prerequisites outrank link errors")
    func blockerMatrix() {
        var discovery = TuiPortDiscovery()
        discovery.reconcile(supportsPreviews: false, privateAddress: nil)
        discovery.request()
        discovery.linkFailed()
        #expect(discovery.state == .unsupported && !discovery.mayScan)
        discovery.reconcile(supportsPreviews: true, privateAddress: nil)
        discovery.linkFailed()
        #expect(discovery.state == .unavailable(.privateAddress))
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.7")
        #expect(discovery.mayScan)
    }

    /// `.notRequested` is what makes a visible Ports group request again after a summary update clears the blocker.
    @Test("A requested machine that gains port support or a new address scans and stays re-requestable")
    func requestedMachineGainingRouteScans() {
        var discovery = TuiPortDiscovery()
        discovery.reconcile(supportsPreviews: false, privateAddress: "10.0.0.7")
        discovery.request()
        #expect(discovery.state == .unsupported && !discovery.mayScan)
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.7")
        #expect(discovery.state == .notRequested && discovery.mayScan)
        _ = discovery.beginScan()
        #expect(discovery.state == .loading)
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.8")
        #expect(discovery.state == .notRequested && discovery.mayScan)
        var idle = TuiPortDiscovery()
        idle.reconcile(supportsPreviews: false, privateAddress: "10.0.0.7")
        idle.reconcile(supportsPreviews: true, privateAddress: "10.0.0.7")
        #expect(idle.state == .notRequested && !idle.mayScan)
    }

    @Test("A routine link failure before any demand keeps Ports not checked yet")
    func linkFailureWithoutDemandKeepsNotRequested() {
        var discovery = readyDiscovery()
        discovery.linkFailed()
        #expect(discovery.state == .notRequested && !discovery.mayScan)
    }

    @Test("Address withdrawal and retirement reject stale results")
    func staleScanCannotPublish() {
        var discovery = readyDiscovery()
        discovery.request()
        let stale = discovery.beginScan()
        discovery.reconcile(supportsPreviews: true, privateAddress: nil)
        let staleCompletion = discovery.complete(TuiPortScanResult(ports: [3000]), request: stale, at: now, socketPath: "old")
        #expect(!staleCompletion)
        #expect(discovery.state == .unavailable(.privateAddress) && discovery.scan == nil)
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.8")
        let retired = discovery.beginScan()
        discovery.invalidate()
        let retiredCompletion = discovery.complete(TuiPortScanResult(ports: [8000]), request: retired, at: now, socketPath: "new")
        #expect(!retiredCompletion)
    }

    @Test("A cache is scoped to its link and does not renew itself on reads")
    func cacheScope() {
        var discovery = readyDiscovery()
        discovery.request()
        let request = discovery.beginScan()
        _ = discovery.complete(TuiPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        let cached = discovery.cachedScan(at: now.addingTimeInterval(20), socketPath: "first", force: false)
        #expect(cached?.ports == [3000])
        let expired = discovery.cachedScan(at: now.addingTimeInterval(31), socketPath: "first", force: false)
        #expect(expired == nil)
        let otherSocket = discovery.cachedScan(at: now, socketPath: "second", force: false)
        #expect(otherSocket == nil)
        let forced = discovery.cachedScan(at: now, socketPath: "first", force: true)
        #expect(forced == nil)
    }

    @Test("Unavailable scans never retain resources belonging to another machine")
    func foreignPortsAreRejected() {
        let owner = SurfaceMachineID.ssh("4c1029697ee358715d3a14a2add817c4b01651440de808371f78165ac90dc581")
        let foreign = CmuxTuiSnapshotParser.portBrowser(machine: .ssh("d9298a10d1b0735837dc4bd85dac641b0f3cef27a47e5d53a54f2f3f5b2fcffa"), port: 3000)
        #expect(CmuxTuiSurfaceProvider.portResources(machine: owner, scannedPorts: nil,
            previousResources: [foreign], privateAddress: "10.0.0.7").isEmpty)
    }

    @Test("The socket exporter carries the same authoritative Ports reason")
    @MainActor
    func socketExportsReason() {
        let states: [TuiPortDiscoveryState] = [.notRequested, .loading, .available, .loopbackOnly,
            .empty(.noListeningService), .unavailable(.privateAddress), .unavailable(.transport), .stale, .unsupported]
        let host = TuiTestHost(destination: "port-owner.example.test")
        for state in states {
            let info = CmuxTuiSurfaceProvider.info(
                from: host.summary,
                linkState: .connected, linkError: nil, portDiscoveryState: state)
            let payload = TerminalController.surfaceMachinePayload(info)
            #expect(payload["id"] as? String == host.machine.rawValue)
            #expect(payload["port_discovery_state"] as? String == state.wireValue)
        }
    }

    private func readyDiscovery() -> TuiPortDiscovery {
        var discovery = TuiPortDiscovery()
        discovery.reconcile(supportsPreviews: true, privateAddress: "10.0.0.7")
        return discovery
    }
}
