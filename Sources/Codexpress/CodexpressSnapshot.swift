import Foundation

struct CodexpressSnapshot: Decodable, Sendable, Equatable {
    let running: Bool
    let mode: String
    let fixedSourceID: String?
    let connectionMode: String?
    let inflight: Int?
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
        let showInCmux: Bool
        let priority: Int
        let health: String?
        let activeRequests: Int?
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
            case showInCmux = "show_in_cmux"
            case activeRequests = "active_requests"
            case cooldownUntil = "cooldown_until"
            case lastError = "last_error"
            case capacityAvailable = "capacity_available"
            case maxActiveConversations = "max_active_conversations"
            case capacityActiveConversations = "capacity_active_conversations"
        }

        var refreshRetryAt: Double? {
            let first = (kind == "official" ? quota?.nextRetryAt : balance?.nextRetryAt)
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let second = (kind == "official" ? credits?.nextRetryAt : nil)
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if let first, let second { return min(first, second) }
            return first ?? second
        }

        var hasRefreshFailure: Bool {
            if kind == "official" {
                return (quota?.failureCount ?? 0) > 0 || (credits?.failureCount ?? 0) > 0
                    || quota?.error != nil || credits?.error != nil
            }
            return (balance?.failureCount ?? 0) > 0
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
        let failureCount: Int?
        let nextRetryAt: Double?

        private enum CodingKeys: String, CodingKey {
            case windows, stale, error
            case fetchedAt = "fetched_at"
            case failureCount = "failure_count"
            case nextRetryAt = "next_retry_at"
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            windows = try values.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
            fetchedAt = try values.decodeIfPresent(Double.self, forKey: .fetchedAt)
            stale = try values.decodeIfPresent(Bool.self, forKey: .stale)
            error = try values.decodeIfPresent(String.self, forKey: .error)
            failureCount = try values.decodeIfPresent(Int.self, forKey: .failureCount)
            nextRetryAt = try values.decodeIfPresent(Double.self, forKey: .nextRetryAt)
        }
    }

    struct QuotaWindow: Decodable, Sendable, Equatable {
        let name: String
        let usedPercent: Double?
        let resetAt: Double?
        let windowSeconds: Double?
        let refCost: Double?

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            usedPercent = try values.decodeIfPresent(Double.self, forKey: .usedPercent)
            resetAt = try values.decodeIfPresent(Double.self, forKey: .resetAt)
            windowSeconds = try values.decodeIfPresent(Double.self, forKey: .windowSeconds)
            // A malformed optional reference must not hide the real quota.
            refCost = try? values.decodeIfPresent(Double.self, forKey: .refCost)
        }

        enum ReferenceLevel {
            case normal, warning, critical
        }

        func referenceProgress(at date: Date) -> Double? {
            guard windowSeconds == 604_800 else { return nil }
            if let resetAt, resetAt.isFinite, resetAt > 0, resetAt <= 253402300799 {
                return min(100, max(0, (resetAt - date.timeIntervalSince1970) / 604_800 * 100))
            }
            guard let refCost, refCost.isFinite, (0...100).contains(refCost) else { return nil }
            return refCost
        }

        func referenceLevel(at date: Date) -> ReferenceLevel {
            guard let reference = referenceProgress(at: date), let usedPercent, usedPercent.isFinite else { return .normal }
            let difference = reference - min(100, max(0, 100 - usedPercent))
            if difference >= 10 { return .critical }
            if difference >= 5 { return .warning }
            return .normal
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case windowSeconds = "window_seconds"
            case refCost = "ref_cost"
        }
    }

    struct Credits: Decodable, Sendable, Equatable {
        let availableCount: Int?
        let fetchedAt: Double?
        let stale: Bool?
        let error: String?
        let failureCount: Int?
        let nextRetryAt: Double?

        private enum CodingKeys: String, CodingKey {
            case stale, error
            case availableCount = "available_count"
            case fetchedAt = "fetched_at"
            case failureCount = "failure_count"
            case nextRetryAt = "next_retry_at"
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
        let failureCount: Int?
        let nextRetryAt: Double?

        private enum CodingKeys: String, CodingKey {
            case status, amount, currency, stale, estimated
            case updatedAt = "updated_at"
            case unknownSpendRequests = "unknown_spend_requests"
            case failureCount = "failure_count"
            case nextRetryAt = "next_retry_at"
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
        showInCmux = try values.decodeIfPresent(Bool.self, forKey: .showInCmux) ?? true
        priority = try values.decode(Int.self, forKey: .priority)
        health = try values.decodeIfPresent(String.self, forKey: .health)
        activeRequests = try values.decodeIfPresent(Int.self, forKey: .activeRequests)
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

/// The endpoint is a display label, never a management or model request destination.
enum CodexpressGateway: Sendable, Equatable {
    struct Revision: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
    }

    struct Remote: Sendable, Equatable {
        let instanceID: String
        let endpoint: String
        let fetchedAt: Date?
        let snapshot: CodexpressSnapshot?

        func isStale(at date: Date) -> Bool {
            guard let fetchedAt else { return true }
            return !(0...60).contains(date.timeIntervalSince(fetchedAt))
        }
    }

    case local(Revision?) // nil only for a legacy installation without a publication
    case remote(Remote)
    case unavailable

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    init(data: Data, revision: Revision) throws {
        struct Publication: Decodable {
            let version: Int
            let mode: String
            let instance_id: String?
            let endpoint: String?
            let fetched_at: Double?
            let snapshot: CodexpressSnapshot?
        }
        let value = try JSONDecoder().decode(Publication.self, from: data)
        guard value.version == 1 else { self = .unavailable; return }
        switch value.mode {
        case "local" where value.instance_id == nil && value.endpoint == nil && value.snapshot == nil && value.fetched_at == nil:
            self = .local(revision)
        case "remote":
            guard let id = value.instance_id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let endpoint = value.endpoint, let url = URLComponents(string: endpoint),
                  url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.percentEncodedPath.isEmpty || url.percentEncodedPath == "/" else {
                self = .unavailable; return
            }
            let date = value.fetched_at.flatMap { (0...253402300799).contains($0) ? Date(timeIntervalSince1970: $0) : nil }
            self = .remote(Remote(instanceID: id, endpoint: endpoint, fetchedAt: date, snapshot: value.snapshot))
        default:
            self = .unavailable
        }
    }
}
