import Foundation

enum CodexpressManagementAction: Sendable {
    case takeover(sourceID: String)
    case cancelTakeover(id: String)
    case recover(sourceID: String)
    case refreshBalance(sourceID: String)
    case refreshQuota(sourceID: String)
    case requestReset(sourceID: String, requestID: UUID)
}
