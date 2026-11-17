public import Foundation
internal import SQLite3

public enum ControlCenterStoreError: Error, LocalizedError, Equatable, Sendable {
    case database(Int32)
    case unsupportedSchema(Int32)
    case invalidRecord
    case privateConfiguration(Int32)
    case insecureConfiguration
    case invalidConfiguration
    case duplicateFavorite

    public var errorDescription: String? {
        switch self {
        case .database(let code): return "Control Center database failed (SQLite \(code))."
        case .unsupportedSchema(let version): return "Unsupported Control Center database version \(version)."
        case .invalidRecord: return "A saved Control Center record is invalid."
        case .privateConfiguration(let code): return "Private connection configuration failed (POSIX \(code))."
        case .insecureConfiguration: return "Connection configuration must be a regular, owner-only (0600) file."
        case .invalidConfiguration: return "Connection configuration is invalid."
        case .duplicateFavorite: return "This session is already saved as another favorite. Edit that favorite instead."
        }
    }
}

public actor ControlCenterStore {
    private let database: ControlCenterDatabase
    private let configurationURL: URL
    private let chatLogURL: URL
    private var chatLogDatabase: ControlCenterChatLogDatabase?

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        configurationURL = directory.appendingPathComponent("connection.json")
        chatLogURL = directory.appendingPathComponent("chat-logs.sqlite3")
        database = try ControlCenterDatabase(url: directory.appendingPathComponent("control-center.sqlite3"))
    }

    public func snapshot() throws -> ControlCenterSnapshot {
        try database.snapshot()
    }

    @discardableResult
    public func saveFavorite(_ target: ControlCenterTarget) throws -> ControlCenterTarget {
        if let identity = target.sessionIdentity {
            let favorites = try database.snapshot().favorites
            if let existing = favorites.first(where: { $0.id != target.id && $0.sessionIdentity == identity }) {
                guard !favorites.contains(where: { $0.id == target.id }) else {
                    throw ControlCenterStoreError.duplicateFavorite
                }
                return existing
            }
        }
        try database.save(target, id: target.id, table: .favorites)
        return target
    }

    public func removeFavorite(_ id: UUID) throws {
        try database.remove(id, table: .favorites)
    }

    public func saveCollection(_ collection: ControlCenterCollection) throws {
        try database.save(collection, id: collection.id, table: .collections)
    }

    public func removeCollection(_ id: UUID) throws {
        try database.remove(id, table: .collections)
    }

    public func updateSessionReferences(migrationID: UUID, sessionID: String, previousFile: String, journal: String, cwd: String) throws {
        try database.updateSessionReferences(migrationID: migrationID, sessionID: sessionID, previousFile: previousFile, journal: journal, cwd: cwd)
    }

    public func savePreference(_ preference: ControlCenterPreference) throws {
        try database.save(preference, id: preference.id, table: .preferences)
    }

    public func removePreference(_ id: UUID) throws {
        try database.remove(id, table: .preferences)
    }

    public func saveOperation(_ operation: ControlCenterOperation) throws {
        try database.save(operation, id: operation.id, table: .operations)
    }

    public func connection() throws -> ControlCenterConnection {
        try ControlCenterPrivateConfiguration.read(configurationURL)
    }

    public func saveConnection(_ connection: ControlCenterConnection) throws {
        try ControlCenterPrivateConfiguration.write(connection, to: configurationURL)
    }

    public func saveConversation(_ conversation: ControlCenterConversation) throws {
        try chatLogs(create: true)?.saveConversation(conversation)
    }

    public func latestConversation() throws -> ControlCenterConversation? {
        try chatLogs()?.latestConversation()
    }

    public func conversation(id: UUID) throws -> ControlCenterConversation? {
        try chatLogs()?.conversation(id: id)
    }

    public func appendChatEvents(conversationID: UUID, events: [ControlCenterChatLogEvent]) throws {
        guard !events.isEmpty else { return }
        try chatLogs(create: true)?.appendEvents(conversationID: conversationID, events: events)
    }

    public func chatEvents(conversationID: UUID) throws -> [ControlCenterChatLogEvent] {
        try chatLogs()?.events(conversationID: conversationID) ?? []
    }

    public func chatLogStatistics() throws -> ControlCenterChatLogStatistics {
        try chatLogs()?.statistics() ?? ControlCenterChatLogStatistics(conversationCount: 0, eventCount: 0, storageBytes: 0)
    }

    public func clearChatLogs() throws {
        chatLogDatabase = nil
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: chatLogURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func chatLogs(create: Bool = false) throws -> ControlCenterChatLogDatabase? {
        if let chatLogDatabase { return chatLogDatabase }
        guard create || FileManager.default.fileExists(atPath: chatLogURL.path) else { return nil }
        let database = try ControlCenterChatLogDatabase(url: chatLogURL)
        chatLogDatabase = database
        return database
    }
}

// The actor is the sole owner; the wrapper makes raw-pointer teardown safe in deinit.
private final class ControlCenterDatabase: @unchecked Sendable {
    enum Table: String, CaseIterable {
        case favorites, collections, preferences, operations
    }

    private let handle: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw ControlCenterStoreError.database(result)
        }
        handle = connection
        try execute("PRAGMA busy_timeout = 5000;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = FULL;")
        let versionStatement = try prepare("PRAGMA user_version;")
        let versionResult = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionResult == SQLITE_ROW else { throw ControlCenterStoreError.database(versionResult) }
        guard version <= 2 else { throw ControlCenterStoreError.unsupportedSchema(version) }
        try execute("BEGIN IMMEDIATE;")
        do {
            for table in Table.allCases {
                try execute("CREATE TABLE IF NOT EXISTS \(table.rawValue) (position INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);")
            }
            try execute("CREATE TABLE IF NOT EXISTS session_reference_migrations (id TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;")
            try execute("PRAGMA user_version = 2;")
            try execute("COMMIT;")
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func snapshot() throws -> ControlCenterSnapshot {
        try execute("BEGIN;")
        do {
            let result = ControlCenterSnapshot(
                favorites: try records(.favorites),
                collections: try records(.collections),
                preferences: try records(.preferences),
                operations: try records(.operations, descending: true)
            )
            try execute("COMMIT;")
            return result
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func save<Value: Encodable>(_ value: Value, id: UUID, table: Table) throws {
        let data = try encoder.encode(value)
        let statement = try prepare("INSERT INTO \(table.rawValue) (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload;")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement)
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw ControlCenterStoreError.database(result) }
        try finish(statement)
    }

    func remove(_ id: UUID, table: Table) throws {
        let statement = try prepare("DELETE FROM \(table.rawValue) WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement)
        try finish(statement)
    }

    func updateSessionReferences(migrationID: UUID, sessionID: String, previousFile: String, journal: String, cwd: String) throws {
        func updated(_ target: ControlCenterTarget) -> ControlCenterTarget {
            guard target.kind == .session, target.agentID == "omp", target.sessionID == sessionID,
                  let file = target.sessionFile else { return target }
            let url = URL(fileURLWithPath: file).standardizedFileURL
            let identity = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
            guard identity == previousFile else { return target }
            var next = target
            next.path = cwd
            next.sessionFile = journal
            return next
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let lookup = try prepare("SELECT 1 FROM session_reference_migrations WHERE id = ?;")
            defer { sqlite3_finalize(lookup) }
            try bind(migrationID, to: lookup)
            let seen = sqlite3_step(lookup)
            guard seen == SQLITE_ROW || seen == SQLITE_DONE else { throw ControlCenterStoreError.database(seen) }
            if seen == SQLITE_ROW {
                try execute("COMMIT;")
                return
            }
            for target: ControlCenterTarget in try records(.favorites) {
                let next = updated(target)
                if next != target { try save(next, id: next.id, table: .favorites) }
            }
            for collection: ControlCenterCollection in try records(.collections) {
                var next = collection
                next.items = collection.items.map(updated)
                if next != collection { try save(next, id: next.id, table: .collections) }
            }
            let remember = try prepare("INSERT INTO session_reference_migrations (id) VALUES (?);")
            defer { sqlite3_finalize(remember) }
            try bind(migrationID, to: remember)
            try finish(remember)
            try execute("COMMIT;")
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func records<Value: Decodable>(_ table: Table, descending: Bool = false) throws -> [Value] {
        let statement = try prepare("SELECT payload FROM \(table.rawValue) ORDER BY position \(descending ? "DESC" : "ASC");")
        defer { sqlite3_finalize(statement) }
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

    private func bind(_ id: UUID, to statement: OpaquePointer) throws {
        let result = id.uuidString.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw ControlCenterStoreError.database(result) }
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
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ControlCenterStoreError.database(result) }
    }
}
