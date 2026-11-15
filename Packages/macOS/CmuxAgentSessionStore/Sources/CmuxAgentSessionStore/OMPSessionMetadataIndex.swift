public import Foundation
internal import Darwin
internal import SQLite3

public enum OMPSessionMetadataIndexError: Error, LocalizedError, Equatable, Sendable {
    case fileSystem(operation: String, code: Int32)
    case insecureDatabase
    case database(operation: String, code: Int32, message: String)
    case unsupportedSchema(Int32)

    public var errorDescription: String? {
        switch self {
        case .fileSystem(let operation, let code):
            return "OMP metadata index \(operation) failed (POSIX \(code))."
        case .insecureDatabase:
            return "OMP metadata index requires an owned private directory and a regular, single-link owner-only database file."
        case .database(let operation, let code, let message):
            return "OMP metadata index \(operation) failed (SQLite \(code)): \(message)"
        case .unsupportedSchema(let version):
            return "OMP metadata index schema \(version) is newer than this application supports."
        }
    }
}

/// A durable discovery cache, partitioned by the caller's effective registration and root identity.
public actor OMPSessionMetadataIndex {
    private let database: OMPMetadataDatabase

    public init(databaseURL: URL) throws {
        database = try OMPMetadataDatabase(url: databaseURL)
    }

    public func isInitialized(namespace: String) throws -> Bool {
        try database.isInitialized(namespace: namespace)
    }

    public func records(namespace: String) throws -> [OMPSessionMetadataRecord] {
        try database.records(namespace: namespace, query: "", cwd: nil, offset: 0, limit: nil)
    }

    public func apply(
        namespace: String,
        upserts: [OMPSessionMetadataRecord],
        removing journalPaths: [String],
        completedScan: Bool
    ) throws {
        try database.apply(namespace: namespace, upserts: upserts, removing: journalPaths, completedScan: completedScan)
    }

    public func search(
        namespace: String,
        query: String,
        cwd: String?,
        offset: Int,
        limit: Int
    ) throws -> [OMPSessionMetadataRecord] {
        guard limit > 0 else { return [] }
        return try database.records(namespace: namespace, query: query, cwd: cwd, offset: max(0, offset), limit: limit)
    }
}

// Only the actor accesses this connection; the wrapper owns raw-pointer teardown.
private final class OMPMetadataDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private static let searchLocale = Locale(identifier: "en_US_POSIX")

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw OMPSessionMetadataIndexError.fileSystem(operation: "open directory", code: errno)
        }
        defer { close(directoryDescriptor) }
        var directoryAttributes = stat()
        guard fstat(directoryDescriptor, &directoryAttributes) == 0 else {
            throw OMPSessionMetadataIndexError.fileSystem(operation: "inspect directory", code: errno)
        }
        guard directoryAttributes.st_uid == geteuid(), (directoryAttributes.st_mode & 0o077) == 0 else {
            throw OMPSessionMetadataIndexError.insecureDatabase
        }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw OMPSessionMetadataIndexError.fileSystem(operation: "open file", code: errno)
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw OMPSessionMetadataIndexError.fileSystem(operation: "inspect file", code: errno)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG, attributes.st_uid == geteuid(), attributes.st_nlink == 1 else {
            throw OMPSessionMetadataIndexError.insecureDatabase
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw OMPSessionMetadataIndexError.fileSystem(operation: "protect file", code: errno)
        }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            directory.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Cannot open database"
            if let connection { sqlite3_close_v2(connection) }
            throw OMPSessionMetadataIndexError.database(operation: "open", code: result, message: message)
        }
        handle = connection
        try execute("PRAGMA busy_timeout = 5000;")
        // A private rollback journal avoids long-lived sidecars for this small, single-writer cache.
        try execute("PRAGMA journal_mode = DELETE;")
        try execute("PRAGMA synchronous = FULL;")
        let statement = try prepare("PRAGMA user_version;")
        let versionResult = sqlite3_step(statement)
        let version = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        guard versionResult == SQLITE_ROW else { throw failure("read schema", code: versionResult) }
        guard version <= 1 else { throw OMPSessionMetadataIndexError.unsupportedSchema(version) }
        if version == 0 {
            try transaction {
                try execute("""
                    CREATE TABLE omp_metadata (
                        namespace TEXT NOT NULL,
                        journal_path TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        title TEXT NOT NULL,
                        cwd TEXT,
                        branch TEXT,
                        modified_at REAL NOT NULL,
                        fingerprint TEXT NOT NULL,
                        title_search TEXT NOT NULL,
                        cwd_search TEXT NOT NULL,
                        session_id_search TEXT NOT NULL,
                        PRIMARY KEY (namespace, journal_path)
                    ) WITHOUT ROWID;
                    CREATE INDEX omp_metadata_recent ON omp_metadata(namespace, modified_at DESC, session_id, journal_path);
                    CREATE TABLE omp_metadata_scans (namespace TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;
                    PRAGMA user_version = 1;
                    """)
            }
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func isInitialized(namespace: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM omp_metadata_scans WHERE namespace = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(namespace, at: 1, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure("read initialization", code: result) }
        return result == SQLITE_ROW
    }

    func apply(
        namespace: String,
        upserts: [OMPSessionMetadataRecord],
        removing journalPaths: [String],
        completedScan: Bool
    ) throws {
        guard !upserts.isEmpty || !journalPaths.isEmpty || completedScan else { return }
        try transaction {
            if !journalPaths.isEmpty {
                let statement = try prepare("DELETE FROM omp_metadata WHERE namespace = ? AND journal_path = ?;")
                defer { sqlite3_finalize(statement) }
                try bind(namespace, at: 1, to: statement)
                for path in journalPaths {
                    try bind(path, at: 2, to: statement)
                    try finish(statement)
                    try check(sqlite3_reset(statement), operation: "reset removal")
                }
            }
            if !upserts.isEmpty {
                let statement = try prepare("""
                    INSERT INTO omp_metadata (
                        namespace, journal_path, session_id, title, cwd, branch, modified_at, fingerprint,
                        title_search, cwd_search, session_id_search
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(namespace, journal_path) DO UPDATE SET
                        session_id = excluded.session_id, title = excluded.title, cwd = excluded.cwd,
                        branch = excluded.branch, modified_at = excluded.modified_at, fingerprint = excluded.fingerprint,
                        title_search = excluded.title_search, cwd_search = excluded.cwd_search,
                        session_id_search = excluded.session_id_search
                    WHERE session_id IS NOT excluded.session_id OR title IS NOT excluded.title
                        OR cwd IS NOT excluded.cwd OR branch IS NOT excluded.branch
                        OR modified_at IS NOT excluded.modified_at OR fingerprint IS NOT excluded.fingerprint;
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(namespace, at: 1, to: statement)
                for record in upserts {
                    let title = String(record.title.prefix(512))
                    try bind(record.journalPath, at: 2, to: statement)
                    try bind(record.sessionID, at: 3, to: statement)
                    try bind(title, at: 4, to: statement)
                    try bind(record.cwd, at: 5, to: statement)
                    try bind(record.branch, at: 6, to: statement)
                    try check(sqlite3_bind_double(statement, 7, record.modifiedAt.timeIntervalSince1970), operation: "bind modification time")
                    try bind(record.fingerprint, at: 8, to: statement)
                    try bind(Self.fold(title), at: 9, to: statement)
                    try bind(Self.fold(record.cwd ?? ""), at: 10, to: statement)
                    try bind(Self.fold(record.sessionID), at: 11, to: statement)
                    try finish(statement)
                    try check(sqlite3_reset(statement), operation: "reset upsert")
                }
            }
            if completedScan {
                let statement = try prepare("INSERT OR IGNORE INTO omp_metadata_scans(namespace) VALUES (?);")
                defer { sqlite3_finalize(statement) }
                try bind(namespace, at: 1, to: statement)
                try finish(statement)
            }
        }
    }

    func records(namespace: String, query: String, cwd: String?, offset: Int, limit: Int?) throws -> [OMPSessionMetadataRecord] {
        var sql = "SELECT journal_path, session_id, title, cwd, branch, modified_at, fingerprint FROM omp_metadata WHERE namespace = ?1"
        if cwd != nil { sql += " AND cwd = ?2" }
        if !query.isEmpty {
            sql += " AND (instr(title_search, ?3) > 0 OR instr(cwd_search, ?3) > 0 OR instr(session_id_search, ?3) > 0)"
        }
        sql += " ORDER BY modified_at DESC, session_id ASC, journal_path ASC"
        if limit != nil { sql += " LIMIT ?4 OFFSET ?5" }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(namespace, at: 1, to: statement)
        if let cwd { try bind(cwd, at: 2, to: statement) }
        if !query.isEmpty { try bind(Self.fold(query), at: 3, to: statement) }
        if let limit {
            try check(sqlite3_bind_int64(statement, 4, Int64(limit)), operation: "bind limit")
            try check(sqlite3_bind_int64(statement, 5, Int64(offset)), operation: "bind offset")
        }
        var records: [OMPSessionMetadataRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW else { throw failure("read metadata", code: result) }
            records.append(OMPSessionMetadataRecord(
                journalPath: text(statement, 0) ?? "",
                sessionID: text(statement, 1) ?? "",
                title: text(statement, 2) ?? "",
                cwd: text(statement, 3),
                branch: text(statement, 4),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                fingerprint: text(statement, 6) ?? ""
            ))
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: searchLocale)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure("prepare", code: result) }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        try check(result, operation: "bind text")
    }

    private func finish(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure("write metadata", code: result) }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil), operation: "execute")
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

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else { throw failure(operation, code: result) }
    }

    private func failure(_ operation: String, code: Int32) -> OMPSessionMetadataIndexError {
        .database(operation: operation, code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
