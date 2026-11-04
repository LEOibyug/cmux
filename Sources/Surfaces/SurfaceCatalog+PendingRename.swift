import CmuxRemoteSession
import Foundation

extension SurfaceCatalog {
    /// Intent remains protected after the RPC returns, until the daemon's accepted
    /// graph passes its receipt. A process-title or notification event in that gap
    /// cannot turn an old tab name into a new local rename.
    func pendingTuiRenameName(for key: TuiRenameCoordinator.Key) -> String? {
        if let name = tuiRenameCoordinator.pendingName(for: key) { return name }
        return tuiStateObservations[key.machine]?.pendingWrites?.first { write in
            switch key.scope {
            case .workspace: return write.kind == .workspaceRename && write.remoteWorkspaceID == key.remoteID
            case .tab: return write.kind == .tabRename && write.remoteTabID == key.remoteID
            case .terminal: return false
            }
        }?.name
    }
}
