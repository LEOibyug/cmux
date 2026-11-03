import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct TuiPortDiscoveryPresentationTests {
    @Test("Reachable services do not need an extra status row", arguments: [
        TuiPortDiscoveryState.available, .loopbackOnly,
    ])
    func reachablePortsStandAlone(state: TuiPortDiscoveryState) {
        #expect(!state.keepsStatusAlongsideRows)
    }

    @Test("Incomplete scans keep their explanation beside retained ports", arguments: [
        TuiPortDiscoveryState.loading, .stale, .unavailable(.transport), .unsupported,
    ])
    func incompleteScanRemainsVisible(state: TuiPortDiscoveryState) {
        #expect(state.keepsStatusAlongsideRows)
    }
}
