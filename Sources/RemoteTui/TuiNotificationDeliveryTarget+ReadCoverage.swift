import CmuxSurfaceCatalogModel
import Foundation

extension TuiNotificationDeliveryTarget {
    /// Whether a read of `target` covers a row placed here, by the rule the
    /// store applies to its own records.
    func isCovered(by target: NotificationReadTarget) -> Bool {
        switch target {
        case .all:
            return true
        case .workspace(let workspaceID):
            return self.workspaceID == workspaceID
        case .surface(let workspaceID, let surfaceID):
            return self.workspaceID == workspaceID && panelID == surfaceID
        }
    }
}
