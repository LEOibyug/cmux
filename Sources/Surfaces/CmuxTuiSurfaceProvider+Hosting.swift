import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    static func info(from summary: RemoteTuiMachine, linkState: SurfaceLinkState, linkError: String?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil, portDiscoveryState: TuiPortDiscoveryState = .notRequested) -> SurfaceMachineInfo {
        SurfaceMachineInfo(id: summary.machine, name: summary.preferredName, status: "running", image: "",
                           memoryMb: nil, diskMb: nil, linkState: linkState,
                           linkError: linkError, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
                           remoteWorkspaces: remoteWorkspaces, privateAddress: summary.preferredPrivateAddress,
                           portDiscoveryState: portDiscoveryState, cpus: nil)
    }
}
