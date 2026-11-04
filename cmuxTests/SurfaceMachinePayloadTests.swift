import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Local and SSH machine catalog payloads")
struct SurfaceMachinePayloadTests {
    private let machine = SurfaceMachineID.ssh(String(repeating: "a", count: 64))

    private func info(_ id: SurfaceMachineID, state: SurfaceLinkState = .connected, error: String? = nil) -> SurfaceMachineInfo {
        SurfaceMachineInfo(id: id, name: "Build host", status: "running", linkState: state, linkError: error,
            remoteWorkspaces: [SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)])
    }

    @Test func machinePayloadUsesOnlyLocalAndSSHIdentity() throws {
        let ssh = TerminalController.surfaceMachinePayload(info(machine))
        #expect(ssh["id"] as? String == machine.rawValue)
        #expect(ssh["kind"] as? String == "ssh")
        #expect(ssh["local"] as? Bool == false)
        #expect(ssh["presence"] == nil)
        #expect(ssh["has_desktop"] == nil)
        let local = TerminalController.surfaceMachinePayload(info(.local, state: .notApplicable))
        #expect(local["kind"] as? String == "local")
        #expect(local["local"] as? Bool == true)
        let encoded = try JSONEncoder().encode(info(machine))
        #expect(try JSONDecoder().decode(SurfaceMachineInfo.self, from: encoded) == info(machine))
    }

    @Test func SSHFailureIsReadableInPayloadAndTree() {
        let failed = info(machine, state: .error, error: "connection_refused")
        let payload = TerminalController.surfaceMachinePayload(failed)
        #expect(payload["link_error"] as? String == "connection_refused")
        #expect(payload["link_error_message"] as? String == failed.linkFailureMessage)
        let lines = CmuxTuiRemoteRouting.treeLines(machine: payload, resources: [])
        #expect(lines.contains { $0.contains(failed.linkFailureMessage) })
        #expect(!lines.contains { $0.contains("connection_refused") })
        #expect(lines.contains { $0.contains("cmux surface tree") })
    }
}
