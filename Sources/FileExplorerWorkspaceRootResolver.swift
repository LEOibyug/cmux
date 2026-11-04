import CmuxSurfaceCatalogModel
import Foundation

/// Both Files presentations resolve local paths or the workspace's explicit SSH transport.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    let catalog: SurfaceCatalog

    init(catalog: SurfaceCatalog? = nil) {
        self.catalog = catalog ?? SurfaceCatalog.shared
    }

    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        if workspace.remoteWorkspaceBinding != nil || workspace.usesRemoteDirectoryProvenance {
            // A projection without an unambiguous workspace owner must never
            // become a local path or silently select a different SSH host.
            if workspace.remoteWorkspaceBinding == nil,
               !workspace.remoteBindingState.projectedResources.isEmpty ||
                catalog.projectionRecords(forWorkspace: workspace.id).contains(where: { !$0.resource.machine.isLocal }) {
                return .none
            }
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else { return .none }
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(destination: configuration.destination,
                    port: configuration.port, identityFile: configuration.identityFile, sshOptions: configuration.fileOperationSSHOptions),
                displayTarget: configuration.displayTarget,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: workspace.remoteConnectionState == .connected,
                unavailableDetail: workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            )
        }
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fresh local workspaces may not have reported a cwd yet.
        let localPath = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : path
        return .local(workspaceId: workspace.id, path: localPath)
    }
}
