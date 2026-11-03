import CmuxSurfaceCatalogModel
import Foundation

extension TuiWorkspaceRenameService {
    enum BindingReconciliation: Equatable {
        case keep
        case clear
        case rebind(machine: SurfaceMachineID, remoteWorkspaceID: String)
    }
}
