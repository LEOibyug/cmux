import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct SurfaceIdentityTests {
    @Test func machineIDRoundTripsThroughItsWireForm() {
        let digest = String(repeating: "a", count: 64)
        let machine = SurfaceMachineID.ssh(digest)
        #expect(SurfaceMachineID(rawValue: "local") == .local)
        #expect(SurfaceMachineID(rawValue: "ssh:\(digest)") == machine)
        #expect(machine.rawValue == "ssh:\(digest)")
        #expect(machine.tuiMachineID == machine.rawValue)
        #expect(SurfaceMachineID.local.isLocal)
    }

    @Test(arguments: ["vm-1", "device:mac@default", "cloud:machine", "ssh:", ""])
    func removedMachineIdentitiesAreRejected(raw: String) {
        #expect(SurfaceMachineID(rawValue: raw) == nil)
    }

    @Test(arguments: ["display", "screen", "device"])
    func removedResourceKindsAreRejected(wire: String) {
        #expect(SurfaceResourceKind(wire: wire) == nil)
    }
}
