import CmuxTui
import CmuxSurfaceCatalogModel
import Foundation

/// One row of the daemon's `notifications` collection.
struct TuiNotificationRow: Hashable, Sendable {
    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        level: String,
        createdAtMs: UInt64,
        terminalID: String? = nil,
        readBy: [String]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.createdAtMs = createdAtMs
        self.terminalID = terminalID
        self.readBy = readBy
    }

    var id: String
    var title: String
    /// `cmux notify --subtitle` inside the machine; nil when the producer gave none.
    var subtitle: String?
    var body: String
    var level: String
    var createdAtMs: UInt64
    var terminalID: String?
    var readBy: [String]

    func isRead(by clientID: String) -> Bool {
        readBy.contains(clientID)
    }

    /// Rows of the accepted state, oldest first. The document keeps the
    /// collection verbatim even though the typed graph does not model it, so
    /// this never re-parses the whole snapshot.
    static func rows(from state: TuiState) -> [TuiNotificationRow] {
        state.otherEntities
            .filter { $0.kind == "notifications" }
            .compactMap { row(fromPayload: $0.payload) }
            .sorted { lhs, rhs in
                if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                return lhs.id < rhs.id
            }
    }

    static func row(fromPayload payload: Data) -> TuiNotificationRow? {
        guard payload.count <= TuiNotificationEvent.maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return row(fromObject: object)
    }

    static func row(fromObject object: [String: Any]) -> TuiNotificationRow? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let title = object["title"] as? String else { return nil }
        let createdAtMs: UInt64
        if let string = object["created_at_ms"] as? String, let value = UInt64(string) {
            createdAtMs = value
        } else if let number = object["created_at_ms"] as? NSNumber, number.int64Value >= 0 {
            createdAtMs = number.uint64Value
        } else {
            createdAtMs = 0
        }
        let readBy = (object["read_by"] as? [Any])?.compactMap { $0 as? String } ?? []
        return TuiNotificationRow(
            id: id,
            title: TuiNotificationTextSanitizer.sanitize(title, maxBytes: TuiNotificationEvent.maxTitleBytes),
            subtitle: (object["subtitle"] as? String).map { TuiNotificationTextSanitizer.sanitize($0, maxBytes: TuiNotificationEvent.maxTitleBytes) }.flatMap { $0.isEmpty ? nil : $0 },
            body: TuiNotificationTextSanitizer.sanitize(object["body"] as? String ?? "", maxBytes: TuiNotificationEvent.maxBodyBytes),
            level: object["level"] as? String ?? "info",
            createdAtMs: createdAtMs,
            terminalID: (object["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            readBy: readBy
        )
    }
}
