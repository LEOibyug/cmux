import CmuxSurfaceCatalogModel
import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudWorkspaceDeleteTestProvider: SurfaceProvider {
    let machine = SurfaceMachineID.ssh("305ea2ddea987cf9e56007652f96f70d181171f04ec850234e2829f8de6ecf84")
    let workspace = SurfaceRemoteWorkspace(id: "ws-delete", name: "Delete me", index: 0, focused: true)
    var onRefresh: () -> Void = {}
    var beforeClose: () throws -> Void = {}
    var beforeTerminalClose: (SurfaceResourceID) throws -> Void = { _ in }
    var refreshGate: (() async -> Void)?
    var closedWorkspaces: [String] = []
    var closedTerminals: [SurfaceResourceID] = []
    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: "Test machine", status: "running", image: nil,
            memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: [workspace])
    }
    var terminal: SurfaceResource {
        SurfaceResource(id: .init(machine: machine, kind: .terminal, key: "term-delete"),
            title: "shell", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: workspace, port: nil, url: nil)
    }
    func refresh() async { onRefresh(); await refreshGate?() }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource { terminal }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func closeTerminal(_ id: SurfaceResourceID) async throws { try beforeTerminalClose(id); closedTerminals.append(id) }
    func closeRemoteWorkspace(id: String) async throws { try beforeClose(); closedWorkspaces.append(id) }
}
