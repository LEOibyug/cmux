import CmuxSurfaceCatalogModel
import Foundation

extension TerminalController {
    nonisolated static func surfaceMachinePayload(_ info: SurfaceMachineInfo) -> [String: Any] {
        let kind: String
        switch info.id {
        case .local: kind = "local"
        case .ssh: kind = "ssh"
        }
        let linkErrorMessage: Any = {
            guard info.id.isSSH, info.linkState != .connected else { return NSNull() }
            return info.linkFailureMessage
        }()
        return [
            "id": info.id.rawValue,
            "local": info.id.isLocal,
            "kind": kind,
            "port_discovery_state": info.portDiscoveryState.wireValue,
            "name": info.name,
            "status": info.status,
            "image": info.image ?? NSNull(),
            "memory_mb": info.memoryMb ?? NSNull(),
            "cpus": info.cpus ?? NSNull(),
            "disk_mb": info.diskMb ?? NSNull(),
            "link_state": info.linkState.rawValue,
            "link_error": info.linkError ?? NSNull(),
            "link_error_message": linkErrorMessage,
            "cpu_percent": info.cpuPercent ?? NSNull(),
            "memory_used_mb": info.memoryUsedMb ?? NSNull(),
            "disk_used_mb": info.diskUsedMb ?? NSNull(),
            "remote_workspaces": info.remoteWorkspaces.map { $0.map(surfaceRemoteWorkspacePayload) } ?? NSNull(),
        ]
    }
}
