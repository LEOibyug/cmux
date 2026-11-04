import Foundation

struct CodexpressSnapshot: Decodable, Sendable, Equatable {
    let running: Bool
    let mode: String
    let fixedSourceID: String?
    let connectionMode: String?
    let inflight: Int
    let sources: [Source]
    let manualRoute: ManualRoute?

    private enum CodingKeys: String, CodingKey {
        case running, mode, inflight, sources
        case fixedSourceID = "fixed_source_id"
        case connectionMode = "connection_mode"
        case manualRoute = "manual_route"
    }

    struct ManualRoute: Decodable, Sendable, Equatable {
        let id: String
        let sourceID: String

        private enum CodingKeys: String, CodingKey {
            case id
            case sourceID = "source_id"
        }
    }

    struct Source: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let kind: String
        let enabled: Bool
        let priority: Int
        let health: String
        let activeRequests: Int
        let cooldownUntil: Double?
        let lastError: String?
        let quota: Quota?
        let credits: Credits?
        let balance: Balance?
        let admission: Admission?
        let capacityAvailable: Bool?
        let maxActiveConversations: Int?
        let capacityActiveConversations: Int?

        fileprivate enum CodingKeys: String, CodingKey {
            case id, name, kind, enabled, priority, health, quota, credits, balance, admission
            case activeRequests = "active_requests"
            case cooldownUntil = "cooldown_until"
            case lastError = "last_error"
            case capacityAvailable = "capacity_available"
            case maxActiveConversations = "max_active_conversations"
            case capacityActiveConversations = "capacity_active_conversations"
        }
    }

    struct Admission: Decodable, Sendable, Equatable {
        let remainingPercent: Double?
        let acceptingNewConversations: Bool?
        let activeConversations: Int?
        let accountActiveConversations: Int?
        let capacityAvailable: Bool?
        let maxActiveConversations: Int?
        let capacityActiveConversations: Int?

        private enum CodingKeys: String, CodingKey {
            case remainingPercent = "remaining_percent"
            case acceptingNewConversations = "accepting_new_conversations"
            case activeConversations = "active_conversations"
            case accountActiveConversations = "account_active_conversations"
            case capacityAvailable = "capacity_available"
            case maxActiveConversations = "max_active_conversations"
            case capacityActiveConversations = "capacity_active_conversations"
        }
    }

    struct Quota: Decodable, Sendable, Equatable {
        let windows: [QuotaWindow]
        let fetchedAt: Double?
        let stale: Bool?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case windows, stale, error
            case fetchedAt = "fetched_at"
        }
    }

    struct QuotaWindow: Decodable, Sendable, Equatable {
        let name: String
        let usedPercent: Double?
        let resetAt: Double?
        let windowSeconds: Double?

        private enum CodingKeys: String, CodingKey {
            case name
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case windowSeconds = "window_seconds"
        }
    }

    struct Credits: Decodable, Sendable, Equatable {
        let availableCount: Int?
        let fetchedAt: Double?
        let stale: Bool?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case stale, error
            case availableCount = "available_count"
            case fetchedAt = "fetched_at"
        }
    }

    struct Balance: Decodable, Sendable, Equatable {
        let status: String?
        let amount: Double?
        let currency: String?
        let stale: Bool?
        let updatedAt: Double?
        let estimated: Bool?
        let unknownSpendRequests: Int?

        private enum CodingKeys: String, CodingKey {
            case status, amount, currency, stale, estimated
            case updatedAt = "updated_at"
            case unknownSpendRequests = "unknown_spend_requests"
        }
    }
}

extension CodexpressSnapshot.Source {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(String.self, forKey: .kind)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        priority = try values.decode(Int.self, forKey: .priority)
        health = try values.decode(String.self, forKey: .health)
        activeRequests = try values.decode(Int.self, forKey: .activeRequests)
        cooldownUntil = try values.decodeIfPresent(Double.self, forKey: .cooldownUntil)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        quota = try values.decodeIfPresent(CodexpressSnapshot.Quota.self, forKey: .quota)
        credits = try values.decodeIfPresent(CodexpressSnapshot.Credits.self, forKey: .credits)
        balance = try values.decodeIfPresent(CodexpressSnapshot.Balance.self, forKey: .balance)
        admission = try values.decodeIfPresent(CodexpressSnapshot.Admission.self, forKey: .admission)
        // The gateway publishes capacity inside admission; preserve the source-level API.
        capacityAvailable = try values.decodeIfPresent(Bool.self, forKey: .capacityAvailable)
            ?? admission?.capacityAvailable
        maxActiveConversations = try values.decodeIfPresent(Int.self, forKey: .maxActiveConversations)
            ?? admission?.maxActiveConversations
        capacityActiveConversations = try values.decodeIfPresent(Int.self, forKey: .capacityActiveConversations)
            ?? admission?.capacityActiveConversations
    }
}
