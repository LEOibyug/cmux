import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Surface machine port discovery Codable")
struct SurfaceMachineInfoPortStateTests {
    private let machineID = SurfaceMachineID.ssh("1521d6953b3f3bd5237868d057651b874c9b5c2cd6422d1cb439dbde786757cc")

    private func machineInfo(state: TuiPortDiscoveryState = .notRequested) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machineID,
            name: "Port state VM",
            status: "running",
            image: "cmux-devbox",
            
            memoryMb: 4096,
            diskMb: 20480,
            linkState: .connected,
            linkError: nil,
            cpuPercent: 12.5,
            memoryUsedMb: 1024,
            diskUsedMb: 4096,
            remoteWorkspaces: [SurfaceRemoteWorkspace(id: "workspace-1", name: "app", index: 0, focused: true)],
            privateAddress: "10.0.0.7",
            portDiscoveryState: state
        )
    }

    @Test("A catalog written before port discovery defaults to not requested")
    func decodesCatalogWithoutPortDiscoveryState() throws {
        let data = try JSONEncoder().encode(machineInfo())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "portDiscoveryState")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SurfaceMachineInfo.self, from: legacyData)

        #expect(decoded.id == machineID)
        #expect(decoded.name == "Port state VM")
        #expect(decoded.privateAddress == "10.0.0.7")
        #expect(decoded.portDiscoveryState == .notRequested)
    }

    @Test("Port discovery states round trip through the catalog codec")
    func roundTripsPortDiscoveryStates() throws {
        let states: [TuiPortDiscoveryState] = [
            .notRequested,
            .loading,
            .available,
            .loopbackOnly,
            .empty(.noListeningService),
            .empty(.otherInterfaceOnly),
            .unavailable(.privateAddress),
            .unavailable(.transport),
            .stale,
            .unsupported,
        ]

        for state in states {
            let data = try JSONEncoder().encode(machineInfo(state: state))
            let decoded = try JSONDecoder().decode(SurfaceMachineInfo.self, from: data)
            #expect(decoded.portDiscoveryState == state)
            #expect(decoded.id == machineID)
            #expect(decoded.remoteWorkspaces?.first?.id == "workspace-1")
        }
    }
}
