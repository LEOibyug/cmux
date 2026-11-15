public import Foundation
internal import Darwin
internal import SQLite3

/// A complete host-owned snapshot. Callers must exclude credentials and request headers.
public struct ControlCenterConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var snapshot: ControlCenterJSON

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date = Date(), snapshot: ControlCenterJSON) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.snapshot = snapshot
    }
}

/// A complete request, response, tool, approval, error or timing record, without credentials.
public struct ControlCenterChatLogEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: String
    public var payload: ControlCenterJSON

    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: String, payload: ControlCenterJSON) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.payload = payload
    }
}

public struct ControlCenterChatLogStatistics: Equatable, Sendable {
    public var conversationCount: Int
    public var eventCount: Int
    /// On-disk file lengths for the dedicated log database and its SQLite sidecars,
    /// including schema/free-page overhead; excludes ordinary records and connection.json.
    public var storageBytes: Int64

    public init(conversationCount: Int, eventCount: Int, storageBytes: Int64) {
        self.conversationCount = conversationCount
        self.eventCount = eventCount
        self.storageBytes = storageBytes
    }
}

// Only ControlCenterStore's actor accesses this connection.
internal final class ControlCenterChatLogDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        self.url = url
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw ControlCenterStoreError.privateConfiguration(errno)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG, attributes.st_uid == geteuid() else {
            throw ControlCenterStoreError.insecureConfiguration
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ControlCenterStoreError.privateConfiguration(errno)
        }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw ControlCenterStoreError.database(result)
        }
        handle = connection
        try execute("PRAGMA busy_timeout = 5000;")
        try execute("PRAGMA journal_mode = DELETE;")
        try execute("PRAGMA synchronous = FULL;")
        try execute("PRAGMA foreign_keys = ON;")
        let version = try integer("PRAGMA user_version;")
        guard version <= 1 else { throw ControlCenterStoreError.unsupportedSchema(Int32(version)) }
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY NOT NULL, updated_at REAL NOT NULL, payload BLOB NOT NULL);")
            try execute("CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated_at DESC, id ASC);")
            try execute("CREATE TABLE IF NOT EXISTS events (position INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, conversation_id TEXT NOT NULL REFERENCES conversations(id), payload BLOB NOT NULL);")
            try execute("CREATE INDEX IF NOT EXISTS events_conversation ON events(conversation_id, position);")
            try execute("PRAGMA user_version = 1;")
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func saveConversation(_ conversation: ControlCenterConversation) throws {
        let statement = try prepare("INSERT INTO conversations (id, updated_at, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, payload = excluded.payload;")
        defer { sqlite3_finalize(statement) }
        try bind(conversation.id, at: 1, to: statement)
        try check(sqlite3_bind_double(statement, 2, conversation.updatedAt.timeIntervalSince1970))
        try bind(encoder.encode(conversation), at: 3, to: statement)
        try finish(statement)
    }

    func latestConversation() throws -> ControlCenterConversation? {
        let statement = try prepare("SELECT payload FROM conversations ORDER BY updated_at DESC, id ASC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        return try rows(statement).first
    }

    func conversation(id: UUID) throws -> ControlCenterConversation? {
        let statement = try prepare("SELECT payload FROM conversations WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        return try rows(statement).first
    }

    func appendEvents(conversationID: UUID, events: [ControlCenterChatLogEvent]) throws {
        let statement = try prepare("INSERT INTO events (id, conversation_id, payload) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        try transaction {
            for event in events {
                try bind(event.id, at: 1, to: statement)
                try bind(conversationID, at: 2, to: statement)
                try bind(encoder.encode(event), at: 3, to: statement)
                try finish(statement)
                try check(sqlite3_reset(statement))
                try check(sqlite3_clear_bindings(statement))
            }
        }
    }

    func events(conversationID: UUID) throws -> [ControlCenterChatLogEvent] {
        let statement = try prepare("SELECT payload FROM events WHERE conversation_id = ? ORDER BY position ASC;")
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement)
        return try rows(statement)
    }

    func statistics() throws -> ControlCenterChatLogStatistics {
        var bytes: Int64 = 0
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return ControlCenterChatLogStatistics(
            conversationCount: try integer("SELECT COUNT(*) FROM conversations;"),
            eventCount: try integer("SELECT COUNT(*) FROM events;"),
            storageBytes: bytes
        )
    }

    private func rows<Value: Decodable>(_ statement: OpaquePointer) throws -> [Value] {
        var values: [Value] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw ControlCenterStoreError.database(result) }
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw ControlCenterStoreError.invalidRecord }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            do { values.append(try decoder.decode(Value.self, from: data)) }
            catch { throw ControlCenterStoreError.invalidRecord }
        }
    }

    private func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw ControlCenterStoreError.database(result) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func bind(_ id: UUID, at index: Int32, to statement: OpaquePointer) throws {
        let result = id.uuidString.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        try check(result)
    }

    private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        try check(result)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ControlCenterStoreError.database(result)
        }
        return statement
    }

    private func finish(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw ControlCenterStoreError.database(result) }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw ControlCenterStoreError.database(result) }
    }
}
