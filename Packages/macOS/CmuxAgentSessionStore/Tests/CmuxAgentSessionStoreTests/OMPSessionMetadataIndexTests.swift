import Foundation
import SQLite3
import Testing
import CmuxAgentSessionStore

@Suite("OMP session metadata index")
struct OMPSessionMetadataIndexTests {
    @Test("records and initialized-empty namespaces survive reopening in a private database")
    func persistence() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let record = metadata("/journals/a.jsonl", id: "native-a", title: "Conversation", cwd: "/work", branch: "topic", time: 100)
        do {
            let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
            #expect(try await !index.isInitialized(namespace: "registered-root"))
            try await index.apply(namespace: "registered-root", upserts: [record], removing: [], completedScan: true)
            try await index.apply(namespace: "empty-root", upserts: [], removing: [], completedScan: true)
        }
        let reopened = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await reopened.records(namespace: "registered-root") == [record])
        #expect(try await reopened.isInitialized(namespace: "registered-root"))
        #expect(try await reopened.isInitialized(namespace: "empty-root"))
        #expect(try await reopened.records(namespace: "empty-root").isEmpty)
        #expect(try await !reopened.isInitialized(namespace: "unknown-root"))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("literal Unicode metadata filtering precedes deterministic paging and keeps namespaces and forks distinct")
    func queries() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let records = [
            metadata("/a", id: "same", title: "Café 中文 100%_\\", cwd: "/Work/Résumé", time: 10),
            metadata("/b", id: "same", title: "CAFE 中文 followup", cwd: "/Work/Résumé", time: 10),
            metadata("/c", id: "z", title: "中文 final", cwd: "/other", time: 10),
            metadata("/d", id: "newest", title: "Unrelated", cwd: "/other", time: 20),
            metadata("/e", id: "ID-Café-中文", title: "Thread", time: 1)
        ]
        try await index.apply(namespace: "one", upserts: records, removing: [], completedScan: true)
        try await index.apply(namespace: "two", upserts: [metadata("/a", id: "foreign", title: "中文", time: 100)], removing: [], completedScan: true)

        let cases: [(String, String?, Int, Int, [String])] = [
            ("", nil, 0, 10, ["/d", "/a", "/b", "/c", "/e"]),
            ("中文", nil, 1, 2, ["/b", "/c"]),
            ("中文", "/Work/Résumé", 1, 1, ["/b"]),
            ("CAFÉ", nil, 0, 10, ["/a", "/b", "/e"]),
            ("cafe\u{301}", nil, 0, 10, ["/a", "/b", "/e"]),
            ("resume", nil, 0, 10, ["/a", "/b"]),
            ("%_\\", nil, 0, 10, ["/a"]),
            ("ID-cafe-中文", nil, 0, 10, ["/e"]),
            ("", "/work/resume", 0, 10, []),
            ("中文", nil, 20, 2, []),
            ("", nil, 0, 0, [])
        ]
        for (query, cwd, offset, limit, paths) in cases {
            let page = try await index.search(namespace: "one", query: query, cwd: cwd, offset: offset, limit: limit)
            #expect(page.map(\.journalPath) == paths)
        }
        #expect(try await index.records(namespace: "two").map(\.sessionID) == ["foreign"])
    }

    @Test("incremental updates and removals preserve initialization until a successful full scan")
    func synchronization() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let original = metadata("/a", id: "a", title: "Before", time: 1)
        let removed = metadata("/b", id: "b", title: "Removed", time: 2)
        try await index.apply(namespace: "root", upserts: [original, removed], removing: [], completedScan: false)
        #expect(try await !index.isInitialized(namespace: "root"))
        let updated = metadata("/a", id: "replacement", title: String(repeating: "界", count: 600), cwd: "/new", branch: "next", time: 3, fingerprint: "changed")
        try await index.apply(namespace: "root", upserts: [updated], removing: ["/b", "/absent"], completedScan: true)
        #expect(try await index.records(namespace: "root") == [updated])
        #expect(try await index.records(namespace: "root").first?.title.count == 512)
        try await index.apply(namespace: "root", upserts: [], removing: ["/a"], completedScan: false)
        #expect(try await index.records(namespace: "root").isEmpty)
        #expect(try await index.isInitialized(namespace: "root"))
    }

    @Test("unchanged rows are not rewritten and a failed batch rolls back removals, upserts and scan completion")
    func transactionFailure() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let original = metadata("/a", id: "a", title: "Original", time: 1)
        try await index.apply(namespace: "root", upserts: [original], removing: [], completedScan: false)
        // Real SQLite failures exercise transaction boundaries without a production injection API.
        try fixture.execute("""
            CREATE TRIGGER reject_rewrites BEFORE UPDATE ON omp_metadata
            BEGIN SELECT RAISE(ABORT, 'unexpected rewrite'); END;
            CREATE TRIGGER reject_record BEFORE INSERT ON omp_metadata
            WHEN NEW.fingerprint = 'reject'
            BEGIN SELECT RAISE(ABORT, 'rejected record'); END;
            """)
        try await index.apply(namespace: "root", upserts: [original], removing: [], completedScan: false)
        let inserted = metadata("/b", id: "b", title: "New", time: 2)
        let rejected = metadata("/c", id: "c", title: "Rejected", time: 3, fingerprint: "reject")
        await #expect(throws: OMPSessionMetadataIndexError.self) {
            try await index.apply(namespace: "root", upserts: [inserted, rejected], removing: ["/a"], completedScan: true)
        }
        #expect(try await index.records(namespace: "root") == [original])
        #expect(try await !index.isInitialized(namespace: "root"))
    }

    @Test("ancestor aliases reopen the same private metadata database")
    func ancestorAlias() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let alias = fixture.directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let record = metadata("/journals/a.jsonl", id: "native-a", title: "Conversation", time: 1)
        let index = try OMPSessionMetadataIndex(databaseURL: alias.appendingPathComponent("private/metadata.sqlite3"))
        try await index.apply(namespace: "root", upserts: [record], removing: [], completedScan: true)
        let reopened = try OMPSessionMetadataIndex(databaseURL: root.appendingPathComponent("private/metadata.sqlite3"))
        #expect(try await reopened.records(namespace: "root") == [record])
    }

    @Test("a symlink cannot redirect the metadata database")
    func rejectsSymlink() throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = fixture.directory.appendingPathComponent("target")
        let contents = Data("do not modify".utf8)
        try contents.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        #expect(throws: OMPSessionMetadataIndexError.self) {
            _ = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        }
        #expect(try Data(contentsOf: target) == contents)
    }

    @Test("managed intent, terminal states and full user metadata survive reopening alongside discovery")
    func managedPersistence() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let sharedID = UUID()
        let records = OMPManagedSessionState.allCases.enumerated().map { offset, state in
            managed(id: offset == 0 ? sharedID : UUID(), state: state, time: Double(offset))
        }
        let discovery = metadata("/active/discovery.jsonl", id: "native", title: "Discovery", time: 10, parentSession: "/active/parent.jsonl")
        let foreign = managed(id: sharedID, namespace: "other", state: .trash, time: 100)
        do {
            let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
            try await index.apply(namespace: "root", upserts: [discovery], removing: [], completedScan: true)
            for record in records + [foreign] { try await index.saveManagedSession(record) }
        }
        let reopened = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await reopened.managedSessions(namespace: "root", limit: 20) == Array(records.reversed()))
        #expect(try await reopened.managedSession(namespace: "root", id: sharedID) == records[0])
        #expect(try await reopened.managedSession(namespace: "other", id: sharedID) == foreign)
        #expect(try await reopened.managedSession(namespace: "absent", id: sharedID) == nil)
        #expect(try await reopened.records(namespace: "root") == [discovery])
        try await reopened.removeManagedSession(namespace: "root", id: sharedID)
        #expect(try await reopened.managedSession(namespace: "root", id: sharedID) == nil)
        #expect(try await reopened.managedSession(namespace: "other", id: sharedID) == foreign)
        let restored = managed(id: sharedID, namespace: "other", state: .restored, time: 100)
        try await reopened.saveManagedSession(restored)
        #expect(try await reopened.managedSessions(namespace: "other", state: .trash, limit: 10).isEmpty)
        #expect(try await reopened.managedSession(namespace: "other", id: sharedID) == restored)
    }

    @Test("managed literal folded search and state filtering precede paging and never cross namespaces")
    func managedQueries() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let first = managed(title: "Café 中文 100%_\\", state: .archived, time: 1)
        let second = managed(title: "CAFE 中文 second", state: .archived, time: 2)
        let trashed = managed(title: "Café 中文 trash", state: .trash, time: 3)
        let unrelated = managed(title: "Unrelated", cwd: "/other", state: .archived, time: 4)
        let foreign = managed(namespace: "other", title: "Café 中文 foreign", state: .archived, time: 5)
        for record in [first, second, trashed, unrelated, foreign] { try await index.saveManagedSession(record) }
        let cases: [(String, OMPManagedSessionState?, Int, Int, [UUID])] = [
            ("cafe\u{301} 中文", .archived, 0, 10, [second.id, first.id]),
            ("CAFÉ 中文", .archived, 1, 1, [first.id]),
            ("%_\\", nil, 0, 10, [first.id]),
            ("resume", .trash, 0, 10, [trashed.id]),
            ("NATIVE-CAFE", .archived, 0, 10, [unrelated.id, second.id, first.id]),
            ("中文", .pending, 0, 10, []),
            ("", nil, 0, 0, []),
            ("中文", nil, 20, 10, [])
        ]
        for (query, state, offset, limit, ids) in cases {
            let page = try await index.managedSessions(namespace: "root", query: query, state: state, offset: offset, limit: limit)
            #expect(page.map(\.id) == ids)
        }
    }

    @Test("invalid managed identifiers and paths cannot replace a durable record")
    func managedValidation() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let original = managed()
        try await index.saveManagedSession(original)
        let invalid = [
            managed(id: original.id, namespace: ""),
            managed(id: original.id, sessionID: "../native"),
            managed(id: original.id, sessionID: "native\0suffix"),
            managed(id: original.id, cwd: "relative"),
            managed(id: original.id, journalPath: "/archive/../outside.jsonl"),
            managed(id: original.id, archiveDirectory: "/archive\0suffix"),
            managed(id: original.id, sourceRoot: "relative"),
            managed(id: original.id, time: .nan)
        ]
        for record in invalid {
            await #expect(throws: OMPSessionMetadataIndexError.self) { try await index.saveManagedSession(record) }
        }
        #expect(try await index.managedSession(namespace: "root", id: original.id) == original)
    }

    @Test("version one migration preserves discovery and initialization while adding managed persistence")
    func managedMigration() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let discovery = metadata("/a", id: "a", title: "Before migration", time: 1)
        do {
            let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
            try await index.apply(namespace: "root", upserts: [discovery], removing: [], completedScan: true)
        }
        try fixture.execute("DROP TABLE omp_managed_sessions; DROP INDEX omp_metadata_cwd; ALTER TABLE omp_metadata DROP COLUMN canonical_cwd; ALTER TABLE omp_metadata DROP COLUMN parent_session; PRAGMA user_version = 1;")
        let migrated = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await migrated.records(namespace: "root") == [discovery])
        #expect(try await migrated.isInitialized(namespace: "root"))
        let record = managed(state: .pending)
        try await migrated.saveManagedSession(record)
        let reopened = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await reopened.managedSession(namespace: "root", id: record.id) == record)
        try fixture.execute("""
            DROP INDEX omp_metadata_cwd;
            DROP INDEX omp_managed_sessions_cwd;
            ALTER TABLE omp_metadata DROP COLUMN canonical_cwd;
            ALTER TABLE omp_managed_sessions DROP COLUMN canonical_cwd;
            PRAGMA user_version = 2;
            """)
        let scopedMigration = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await scopedMigration.managedSessions(namespace: "root", limit: 10, canonicalCwdRoot: "/Work") == [record])
        #expect(try await scopedMigration.records(namespace: "root") == [discovery])
    }

    @Test("fingerprint lookups isolate namespaces and select exact journal paths without display metadata")
    func fingerprintLookup() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        try await index.apply(namespace: "root", upserts: [
            metadata("/a", id: "a", title: "One", time: 1, fingerprint: "first"),
            metadata("/b", id: "b", title: "Two", time: 2, fingerprint: "second")
        ], removing: [], completedScan: true)
        try await index.apply(namespace: "other", upserts: [metadata("/a", id: "a", title: "Other", time: 1, fingerprint: "foreign")], removing: [], completedScan: true)
        #expect(try await index.fingerprints(namespace: "root") == ["/a": "first", "/b": "second"])
        #expect(try await index.fingerprints(namespace: "root", journalPaths: ["/a", "/a", "/absent"]) == ["/a": "first"])
        #expect(try await index.fingerprints(namespace: "root", journalPaths: []).isEmpty)
        #expect(try await index.fingerprints(namespace: "missing").isEmpty)
    }

    @Test("canonical scope filters before paging and explicit refresh resolves aliases without changing logical metadata")
    func canonicalScope() async throws {
        let fixture = MetadataIndexFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scope = fixture.directory.appendingPathComponent("work")
        let child = scope.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = fixture.directory.appendingPathComponent("logical")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let old = child.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: child.appendingPathComponent("renamed"))
        let logicalCwd = alias.path + "/old/deep"
        let dangling = scope.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: scope.appendingPathComponent("absent"))
        let cycle = scope.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: cycle)
        let escape = scope.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: fixture.directory)
        let canonicalRoot = scope.resolvingSymlinksInPath().path
        let index = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        let inside = metadata("/native/inside.jsonl", id: "inside", title: "Café", cwd: logicalCwd, time: 1)
        let exact = metadata("/native/exact.jsonl", id: "exact", title: "Café", cwd: scope.path, time: 2)
        let sibling = metadata("/native/sibling.jsonl", id: "sibling", title: "Café", cwd: scope.path + "-other", time: 3)
        let unknown = metadata("/native/unknown.jsonl", id: "unknown", title: "Café", time: 4)
        let invalid = [dangling.path + "/missing", cycle.path + "/missing", escape.path + "/missing", scope.path + "/escape/../work/child", scope.path + "/missing/../escape/missing", scope.path + "/missing/../dangling/../child"].enumerated().map { offset, cwd in
            metadata("/native/invalid-\(offset).jsonl", id: "invalid-\(offset)", title: "Café", cwd: cwd, time: 5 + Double(offset))
        }
        try await index.apply(namespace: "root", upserts: [inside, exact, sibling, unknown] + invalid, removing: [], completedScan: true)
        try await index.apply(namespace: "foreign", upserts: [inside], removing: [], completedScan: true)
        let page = try await index.search(namespace: "root", query: "cafe", cwd: nil, offset: 1, limit: 1, canonicalCwdRoot: canonicalRoot)
        #expect(page == [inside])
        #expect(try await index.search(namespace: "root", query: "cafe", cwd: nil, offset: 0, limit: 10, canonicalCwdRoot: canonicalRoot) == [exact, inside])
        let owned = managed(cwd: logicalCwd, state: .pending, time: 1)
        let foreign = managed(id: owned.id, namespace: "foreign", cwd: logicalCwd, state: .pending, time: 1)
        let outside = managed(cwd: scope.path + "-other", state: .pending, time: 2)
        try await index.saveManagedSession(owned)
        try await index.saveManagedSession(outside)
        try await index.saveManagedSession(foreign)
        #expect(try await index.managedSessions(namespace: "root", query: "cafe", state: .pending, limit: 1, canonicalCwdRoot: canonicalRoot) == [owned])
        #expect(try await index.managedSession(namespace: "root", id: outside.id, canonicalCwdRoot: canonicalRoot) == nil)
        // The committed scope index does not follow filesystem changes on each warm query.
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        #expect(try await index.search(namespace: "root", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot) == [inside])
        try await index.refreshCanonicalCwds(namespace: "root")
        #expect(try await index.search(namespace: "root", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot).isEmpty)
        #expect(try await index.managedSession(namespace: "root", id: owned.id, canonicalCwdRoot: canonicalRoot) == nil)
        #expect(try await index.search(namespace: "foreign", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot) == [inside])
        #expect(try await index.managedSession(namespace: "foreign", id: owned.id, canonicalCwdRoot: canonicalRoot) == foreign)
        // A failed symlink resolution is never cached as a lexical in-scope cwd.
        for destination in [scope.appendingPathComponent("absent"), alias] {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
            try await index.refreshCanonicalCwds(namespace: "root")
            #expect(try await index.search(namespace: "root", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot).isEmpty)
            #expect(try await index.managedSession(namespace: "root", id: owned.id, canonicalCwdRoot: canonicalRoot) == nil)
        }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        #expect(try await index.search(namespace: "root", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot).isEmpty)
        try await index.refreshCanonicalCwds(namespace: "root")
        let reopened = try OMPSessionMetadataIndex(databaseURL: fixture.url)
        #expect(try await reopened.search(namespace: "root", query: "inside", cwd: nil, offset: 0, limit: 1, canonicalCwdRoot: canonicalRoot) == [inside])
        #expect(try await reopened.managedSession(namespace: "root", id: owned.id, canonicalCwdRoot: canonicalRoot) == owned)
        #expect(try await reopened.managedSession(namespace: "root", id: outside.id) == outside)
        #expect(try await reopened.records(namespace: "root").count == 4 + invalid.count)
        #expect(try await reopened.fingerprints(namespace: "root")[inside.journalPath] == inside.fingerprint)
    }
}

private func metadata(
    _ path: String,
    id: String,
    title: String,
    cwd: String? = nil,
    branch: String? = nil,
    time: TimeInterval,
    fingerprint: String = "signature",
    parentSession: String? = nil
) -> OMPSessionMetadataRecord {
    OMPSessionMetadataRecord(journalPath: path, sessionID: id, title: title, cwd: cwd, branch: branch, modifiedAt: Date(timeIntervalSince1970: time), fingerprint: fingerprint, parentSession: parentSession)
}

private func managed(
    id: UUID = UUID(),
    namespace: String = "root",
    sessionID: String = "native-café",
    title: String = "  Café 中文 " + String(repeating: "界", count: 600) + "  ",
    cwd: String = "/Work/Résumé",
    journalPath: String = "/archive/current.jsonl",
    archiveDirectory: String = "/archive/owned",
    sourceRoot: String = "/active",
    state: OMPManagedSessionState = .pending,
    time: TimeInterval = 1
) -> OMPManagedSessionRecord {
    OMPManagedSessionRecord(
        id: id, namespace: namespace, sessionID: sessionID, title: title, cwd: cwd,
        originalJournalPath: "/active/original.jsonl", journalPath: journalPath,
        archiveDirectory: archiveDirectory, sourceRoot: sourceRoot, state: state,
        createdAt: Date(timeIntervalSince1970: time), parentSession: "/active/parent.jsonl"
    )
}

private struct MetadataIndexFixture {
    let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/omp-metadata-tests-\(UUID().uuidString)", isDirectory: true)

    var url: URL { directory.appendingPathComponent("metadata.sqlite3") }

    func execute(_ sql: String) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw FixtureError.sqlite(result)
        }
        defer { sqlite3_close_v2(connection) }
        let executed = sqlite3_exec(connection, sql, nil, nil, nil)
        guard executed == SQLITE_OK else { throw FixtureError.sqlite(executed) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private enum FixtureError: Error {
        case sqlite(Int32)
    }
}
