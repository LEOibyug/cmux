import CmuxSurfaceCatalogModel
import Foundation

/// Where a daemon notification lands locally: the workspace bound to the
/// machine, and the pane showing the terminal when one is open here.
struct TuiNotificationDeliveryTarget: Equatable, Sendable {
    init(
        workspaceID: UUID,
        panelID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }

    var workspaceID: UUID
    var panelID: UUID?
}
