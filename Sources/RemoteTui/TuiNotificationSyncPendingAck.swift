import CmuxSurfaceCatalogModel
import Foundation

/// One idempotent batch of SSH notification read acknowledgements.
struct TuiNotificationSyncPendingAck: Codable, Equatable, Sendable {
    var key: String
    var ids: [String]

    init(
        key: String,
        ids: [String]
    ) {
        self.key = key
        self.ids = ids
    }
}
