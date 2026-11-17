import Foundation
import Darwin
import Testing
import CmuxControlCenter

func controlCenterTestDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tmp/tests/\(UUID().uuidString)", isDirectory: true)
}

@Suite("Control Center durable storage")
struct ControlCenterStoreTests {
    @Test func changesSurviveReopeningWithoutLosingCollectionOrderOrReceipts() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ControlCenterTarget(name: "Exact session", kind: .session, path: "/logical/project", sessionID: "session-42", sessionFile: "/sessions/42.jsonl")
        var second = ControlCenterTarget(name: "Directory", kind: .directory, path: "/logical/project")
        second.name = "Renamed directory"
        let collection = ControlCenterCollection(name: "Daily", items: [second, first])
        let preference = ControlCenterPreference(key: "language", value: "Chinese", scope: "/logical/project", updatedAt: Date(timeIntervalSince1970: 1000))
        var receipt = ControlCenterOperation(title: "Open Daily", createdAt: Date(timeIntervalSince1970: 2000))
        receipt.steps = [
            ControlCenterStep(targetID: second.id, title: "Directory", status: .success, detail: "Opened", workspaceID: "workspace-1"),
            ControlCenterStep(targetID: first.id, title: "Exact session", status: .blocked, detail: "Lease held elsewhere")
        ]
        try await populate(directory, first: first, second: second, collection: collection, preference: preference, receipt: receipt)
        let reopened = try ControlCenterStore(directory: directory)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.favorites == [second])
        #expect(snapshot.collections == [collection])
        #expect(snapshot.preferences == [preference])
        #expect(snapshot.operations == [receipt])
        try await reopened.removeCollection(collection.id)
        try await reopened.removePreference(preference.id)
        let afterDelete = try await ControlCenterStore(directory: directory).snapshot()
        #expect(afterDelete.collections.isEmpty)
        #expect(afterDelete.preferences.isEmpty)
        #expect(afterDelete.favorites == [second])
        #expect(afterDelete.operations == [receipt])
    }

    private func populate(_ directory: URL, first: ControlCenterTarget, second: ControlCenterTarget, collection: ControlCenterCollection, preference: ControlCenterPreference, receipt: ControlCenterOperation) async throws {
        let store = try ControlCenterStore(directory: directory)
        try await store.saveFavorite(first)
        var oldSecond = second
        oldSecond.name = "Old name"
        try await store.saveFavorite(oldSecond)
        try await store.saveFavorite(second)
        try await store.removeFavorite(first.id)
        var oldCollection = collection
        oldCollection.items.reverse()
        try await store.saveCollection(oldCollection)
        try await store.saveCollection(collection)
        var oldPreference = preference
        oldPreference.value = "English"
        try await store.savePreference(oldPreference)
        try await store.savePreference(preference)
        var partial = receipt
        partial.steps.removeLast()
        try await store.saveOperation(partial)
        try await store.saveOperation(receipt)
    }

    @Test func legacyCollectionSessionsDefaultToOMP() throws {
        let json = """
        {"id":"00112233-4455-6677-8899-AABBCCDDEEFF","name":"Daily","items":[{"id":"11223344-5566-7788-99AA-BBCCDDEEFF00","name":"Old session","kind":"session","path":"/project","sessionID":"shared-id","sessionFile":"/sessions/old.jsonl"}]}
        """
        let collection = try JSONDecoder().decode(ControlCenterCollection.self, from: Data(json.utf8))
        let target = try #require(collection.items.first)
        #expect(target.agentID == "omp")
        let omp = ControlCenterTarget(name: "New search result", kind: .session, path: "/project", sessionID: "shared-id")
        let claude = ControlCenterTarget(name: "Other agent", kind: .session, path: "/project", sessionID: "shared-id", agentID: "claude")
        #expect(target.sessionIdentity == omp.sessionIdentity)
        #expect(target.sessionIdentity != claude.sessionIdentity)
    }

    @Test func sessionBookmarksKeepSavedIdentityAcrossSearchesAndReopening() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let omp = ControlCenterTarget(name: "Saved OMP name", kind: .session, path: "/project", sessionID: "shared-id", sessionFile: "/sessions/omp.jsonl")
        let claude = ControlCenterTarget(name: "Claude", kind: .session, path: "/project", sessionID: "shared-id", agentID: "claude")
        let store = try ControlCenterStore(directory: directory)
        try await store.saveFavorite(omp)
        try await store.saveFavorite(claude)
        let newSearch = ControlCenterTarget(name: "New search title", kind: .session, path: "/project", sessionID: "shared-id")
        let saved = try await store.saveFavorite(newSearch)
        #expect(saved == omp)
        let collection = ControlCenterCollection(name: "Both agents", items: [saved, claude])
        try await store.saveCollection(collection)

        let reopened = try ControlCenterStore(directory: directory)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.favorites == [omp, claude])
        #expect(snapshot.collections == [collection])
        var collidingEdit = claude
        collidingEdit.agentID = "omp"
        await #expect(throws: ControlCenterStoreError.duplicateFavorite) {
            try await reopened.saveFavorite(collidingEdit)
        }
        #expect(try await reopened.snapshot().favorites == [omp, claude])
        try await reopened.removeFavorite(saved.id)
        #expect(try await ControlCenterStore(directory: directory).snapshot().favorites == [claude])
    }

    @Test func managementScopeResolvesAliasesWithoutAdmittingNeighboringOrEscapingDirectories() throws {
        let root = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let project = managed.appendingPathComponent("项目", isDirectory: true)
        let outside = root.appendingPathComponent("managed-other", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
        try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("escape"), withDestinationURL: outside)
        let scope = try ControlCenterSessionScope(directory: alias.path)
        #expect(scope.contains(alias.appendingPathComponent("项目").path))
        #expect(scope.contains(project.path))
        #expect(!scope.contains(outside.path))
        #expect(!scope.contains(alias.appendingPathComponent("escape").path))
        try FileManager.default.moveItem(at: project, to: managed.appendingPathComponent("renamed"))
        #expect(scope.contains(alias.appendingPathComponent("项目").path))
        #expect(scope.contains(alias.path + "/项目/deep/missing"))
        #expect(scope.contains(alias.path + "/missing/../renamed"))
        #expect(!scope.contains(alias.path + "/escape/missing"))
        #expect(!scope.contains(alias.path + "/escape/../renamed"))
        #expect(!scope.contains(alias.path + "/missing/../escape/missing"))
        let dangling = managed.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: managed.appendingPathComponent("absent"))
        #expect(!scope.contains(alias.path + "/missing/../dangling/../renamed"))
        let cycle = managed.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: cycle)
        let file = managed.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        for path in [dangling.path, dangling.path + "/missing", cycle.path, cycle.path + "/missing", file.path, file.path + "/missing"] {
            #expect(!scope.contains(path))
        }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        #expect(try ControlCenterSessionScope(directory: alias.path) != scope)
        #expect(!scope.contains(alias.appendingPathComponent("项目").path))
        #expect(!scope.contains(alias.path + "/项目/deep/missing"))
    }

    @Test func directoryChangesRetargetOnlyExactSavedCopiesAndKeepCollectionOrder() async throws {
        let root = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ControlCenterStore(directory: root)
        let old = root.appendingPathComponent("old.jsonl").resolvingSymlinksInPath().path
        let next = root.appendingPathComponent("next.jsonl").path
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let original = ControlCenterTarget(name: "Custom bookmark", kind: .session, path: "/old", sessionID: "same-id", sessionFile: alias.appendingPathComponent("old.jsonl").path)
        let otherCopy = ControlCenterTarget(name: "Other physical copy", kind: .session, path: "/old", sessionID: "same-id", sessionFile: root.appendingPathComponent("other.jsonl").path)
        let otherAgent = ControlCenterTarget(name: "Other source", kind: .session, path: "/old", sessionID: "same-id", sessionFile: old, agentID: "claude")
        let folder = ControlCenterTarget(name: "Project", kind: .directory, path: "/old")
        let collection = ControlCenterCollection(name: "Ordered", items: [folder, original, otherCopy, otherAgent])
        try await store.saveFavorite(original)
        try await store.saveFavorite(otherAgent)
        try await store.saveCollection(collection)
        let firstMigration = UUID()
        try await store.updateSessionReferences(migrationID: firstMigration, sessionID: "same-id", previousFile: old, journal: next, cwd: "/new")
        var updated = original
        updated.path = "/new"
        updated.sessionFile = next
        let snapshot = try await ControlCenterStore(directory: root).snapshot()
        #expect(snapshot.favorites == [updated, otherAgent])
        #expect(snapshot.collections == [ControlCenterCollection(id: collection.id, name: collection.name, items: [folder, updated, otherCopy, otherAgent])])
        try await store.updateSessionReferences(migrationID: UUID(), sessionID: "same-id", previousFile: next, journal: old, cwd: "/old")
        try await store.updateSessionReferences(migrationID: firstMigration, sessionID: "same-id", previousFile: old, journal: next, cwd: "/new")
        var returned = original
        returned.sessionFile = old
        let afterReplay = try await ControlCenterStore(directory: root).snapshot()
        #expect(afterReplay.favorites == [returned, otherAgent])
        #expect(afterReplay.collections == [ControlCenterCollection(id: collection.id, name: collection.name, items: [folder, returned, otherCopy, otherAgent])])
    }

    @Test func connectionIsPrivateAndNeverWrittenIntoDatabase() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControlCenterStore(directory: directory)
        #expect(try await store.connection() == ControlCenterConnection())
        var connection = ControlCenterConnection(model: "chosen-model", apiKey: "private-test-key-726a")
        try await store.saveConnection(connection)
        connection.apiKey = "replacement-private-key-981b"
        try await store.saveConnection(connection)
        let reopened = try ControlCenterStore(directory: directory)
        #expect(try await reopened.connection() == connection)
        let url = directory.appendingPathComponent("connection.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent != "connection.json" {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data("private-test-key-726a".utf8)) == nil)
            #expect(bytes.range(of: Data(connection.apiKey.utf8)) == nil)
        }
        #expect(chmod(url.path, 0o644) == 0)
        await #expect(throws: ControlCenterStoreError.insecureConfiguration) { try await reopened.connection() }
    }

    @Test func malformedFilesAreNotReplacedByEmptyState() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("control-center.sqlite3")
        let corrupt = Data("not a SQLite database".utf8)
        try corrupt.write(to: database)
        #expect(throws: ControlCenterStoreError.self) { try ControlCenterStore(directory: directory) }
        #expect(try Data(contentsOf: database) == corrupt)
        try FileManager.default.removeItem(at: database)
        let store = try ControlCenterStore(directory: directory)
        let config = directory.appendingPathComponent("connection.json")
        try Data("{broken".utf8).write(to: config)
        #expect(chmod(config.path, 0o600) == 0)
        await #expect(throws: ControlCenterStoreError.invalidConfiguration) { try await store.connection() }
    }
}
