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
}

private func metadata(
    _ path: String,
    id: String,
    title: String,
    cwd: String? = nil,
    branch: String? = nil,
    time: TimeInterval,
    fingerprint: String = "signature"
) -> OMPSessionMetadataRecord {
    OMPSessionMetadataRecord(journalPath: path, sessionID: id, title: title, cwd: cwd, branch: branch, modifiedAt: Date(timeIntervalSince1970: time), fingerprint: fingerprint)
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
