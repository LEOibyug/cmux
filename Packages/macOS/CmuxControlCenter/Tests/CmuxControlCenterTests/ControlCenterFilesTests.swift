import Foundation
import Darwin
import Testing
import CmuxControlCenter

@Suite("Control Center file runtime")
struct ControlCenterFilesTests {
    @Test func overwriteRetainsOriginalBytesMetadataAndPrivatePersistentBackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("binary")
        let original = Data([0, 255, 128, 10, 13, 65])
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let key = "user.cmux-file-test"
        let attribute = Data("preserved".utf8)
        let attributeStatus = attribute.withUnsafeBytes { setxattr(source.path, key, $0.baseAddress, $0.count, 0, 0) }
        #expect(attributeStatus == 0)
        let plan = try ControlCenterFiles.planWrite(path: source.path, content: "replacement")
        let root = directory.appendingPathComponent("backups")
        let result = try ControlCenterFiles.apply(plan, backupRoot: root)
        let backup = URL(fileURLWithPath: try #require(result.backupPath))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
        #expect(try permissions(source) == 0o640)
        #expect(try permissions(backup) == 0o640)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(backup.deletingLastPathComponent()) == 0o700)
        var value = [UInt8](repeating: 0, count: 64)
        let count = value.withUnsafeMutableBytes { getxattr(source.path, key, $0.baseAddress, $0.count, 0, 0) }
        #expect(count == attribute.count)
        #expect(Data(value.prefix(max(0, count))) == attribute)
        let backupCount = value.withUnsafeMutableBytes { getxattr(backup.path, key, $0.baseAddress, $0.count, 0, 0) }
        #expect(backupCount == attribute.count)
        #expect(Data(value.prefix(max(0, backupCount))) == attribute)
        let metadata = try Data(contentsOf: backup.deletingLastPathComponent().appendingPathComponent("metadata.json"))
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        #expect(object["path"] as? String == source.resolvingSymlinksInPath().path)
        #expect(object["sha256"] as? String == result.previousSHA256)
        #expect(result.sha256 == plan.newSHA256)
        // A backup remains usable independently of the plan or source file's later lifetime.
        try FileManager.default.removeItem(at: source)
        let restored = try ControlCenterFiles.planWrite(path: source.path, content: original.base64EncodedString(), encoding: "base64")
        let restoredResult = try ControlCenterFiles.apply(restored, backupRoot: root)
        #expect(restoredResult.backupPath == nil)
        #expect(try Data(contentsOf: source) == Data(contentsOf: backup))
    }

    @Test func readsLosslessBoundedBytePagesAndHashesWholeFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pages")
        let content = Data("hello 🐈 world".utf8)
        try content.write(to: source)
        let first = try ControlCenterFiles.read(path: source.path, limit: 6)
        #expect(first.text == "hello " && first.encoding == "utf8")
        #expect(first.size == content.count && first.offset == 0 && first.nextOffset == 6 && first.truncated)
        let split = try ControlCenterFiles.read(path: source.path, offset: 6, limit: 2)
        #expect(split.encoding == "base64")
        #expect(Data(base64Encoded: split.text) == content.subdata(in: 6..<8))
        let rest = try ControlCenterFiles.read(path: source.path, offset: 8)
        #expect(split.sha256 == first.sha256 && rest.sha256 == first.sha256)
        #expect(rest.nextOffset == nil)
        let recovered = Data(first.text.utf8) + (try #require(Data(base64Encoded: split.text))) + (try #require(Data(base64Encoded: rest.text)))
        #expect(recovered == content)
        let beyond = try ControlCenterFiles.read(path: source.path, offset: Int.max, limit: Int.max)
        #expect(beyond.text.isEmpty && beyond.nextOffset == nil)
        let binary = Data(repeating: 255, count: 100_000)
        try binary.write(to: source)
        let bounded = try ControlCenterFiles.read(path: source.path, limit: Int.max)
        #expect(bounded.encoding == "base64" && bounded.text.utf8.count <= 48_000)
        #expect(bounded.nextOffset != nil && bounded.truncated && bounded.size == binary.count)
        #expect(Data(base64Encoded: bounded.text) == binary.prefix(try #require(bounded.nextOffset)))
        try Data("abc".utf8).write(to: source)
        let known = try ControlCenterFiles.read(path: source.path)
        #expect(known.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let encoded = try JSONEncoder().encode(known)
        #expect(try JSONDecoder().decode(ControlCenterFileRead.self, from: encoded).text == "abc")
    }

    @Test func editsAreExactUniqueAndReplaceAllIsExplicit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("text")
        try "café cafe\u{301}\nrepeat repeat".write(to: source, atomically: false, encoding: .utf8)
        let root = directory.appendingPathComponent("backups")
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planEdit(path: source.path, oldText: "repeat", newText: "one") }
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planEdit(path: source.path, oldText: "missing", newText: "one") }
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planEdit(path: source.path, oldText: "", newText: "one") }
        let first = try ControlCenterFiles.planEdit(path: source.path, oldText: "café", newText: "changed")
        _ = try ControlCenterFiles.apply(first, backupRoot: root)
        #expect(try Data(contentsOf: source) == Data("changed cafe\u{301}\nrepeat repeat".utf8))
        let all = try ControlCenterFiles.planEdit(path: source.path, oldText: "repeat", newText: "✓", replaceAll: true)
        _ = try ControlCenterFiles.apply(all, backupRoot: root)
        #expect(try Data(contentsOf: source) == Data("changed cafe\u{301}\n✓ ✓".utf8))
        try "aaa".write(to: source, atomically: false, encoding: .utf8)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planEdit(path: source.path, oldText: "aa", newText: "x") }
        try Data([255]).write(to: source)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planEdit(path: source.path, oldText: "x", newText: "y") }
    }

    @Test func staleHashesChangedSourcesAndNewTargetCollisionsNeverOverwrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("target")
        let root = directory.appendingPathComponent("backups")
        try "original".write(to: source, atomically: false, encoding: .utf8)
        let hash = try ControlCenterFiles.read(path: source.path).sha256
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.planWrite(path: source.path, content: "new", expectedSHA256: "wrong") }
        let planned = try ControlCenterFiles.planWrite(path: source.path, content: "planned", expectedSHA256: hash)
        try "external".write(to: source, atomically: false, encoding: .utf8)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.apply(planned, backupRoot: root) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "external")
        // Replacing an inode with identical bytes is still a stale source, not permission to overwrite it.
        let sameBytes = try ControlCenterFiles.planWrite(path: source.path, content: "planned")
        try FileManager.default.removeItem(at: source)
        try "external".write(to: source, atomically: false, encoding: .utf8)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.apply(sameBytes, backupRoot: root) }
        let newPath = directory.appendingPathComponent("new")
        let create = try ControlCenterFiles.planWrite(path: newPath.path, content: "planned")
        try "racer".write(to: newPath, atomically: false, encoding: .utf8)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.apply(create, backupRoot: root) }
        #expect(try String(contentsOf: newPath, encoding: .utf8) == "racer")
        try FileManager.default.removeItem(at: newPath)
        let result = try ControlCenterFiles.apply(create, backupRoot: root)
        #expect(result.backupPath == nil && result.previousSHA256 == nil)
        #expect(try String(contentsOf: newPath, encoding: .utf8) == "planned")
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.apply(create, backupRoot: root) }
    }

    @Test func backupFailureLeavesOriginalIntactAndNoReplacementArtifact() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let unavailableRoot = directory.appendingPathComponent("not-a-directory")
        try "original".write(to: source, atomically: false, encoding: .utf8)
        try "blocker".write(to: unavailableRoot, atomically: false, encoding: .utf8)
        let plan = try ControlCenterFiles.planWrite(path: source.path, content: "replacement")
        #expect(throws: (any Error).self) { try ControlCenterFiles.apply(plan, backupRoot: unavailableRoot) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names) == ["source", "not-a-directory"])
    }

    @Test func cancelledApplyDoesNotPublishOrCreateBackups() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let root = directory.appendingPathComponent("backups")
        try "original".write(to: source, atomically: false, encoding: .utf8)
        let plan = try ControlCenterFiles.planWrite(path: source.path, content: "replacement")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ControlCenterFiles.apply(plan, backupRoot: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func symlinkApprovalBindsResolvedTargetWithoutReplacingTheLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let link = directory.appendingPathComponent("link")
        try "first".write(to: first, atomically: false, encoding: .utf8)
        try "second".write(to: second, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let plan = try ControlCenterFiles.planWrite(path: link.path, content: "replacement")
        #expect(plan.requestedPath == link.path)
        #expect(plan.path == first.resolvingSymlinksInPath().path)
        #expect(try ControlCenterFiles.read(path: link.path).path == plan.path)
        let root = directory.appendingPathComponent("backups")
        _ = try ControlCenterFiles.apply(plan, backupRoot: root)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == first.path)
        #expect(try String(contentsOf: first, encoding: .utf8) == "replacement")
        let stale = try ControlCenterFiles.planEdit(path: link.path, oldText: "replacement", newText: "stale")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(throws: ControlCenterFileError.self) { try ControlCenterFiles.apply(stale, backupRoot: root) }
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        // A dangling symlink authorizes creation of its disclosed target, never replacement of the link.
        let absent = directory.appendingPathComponent("absent")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: absent)
        let create = try ControlCenterFiles.planWrite(path: link.path, content: "created")
        #expect(create.path == directory.resolvingSymlinksInPath().appendingPathComponent("absent").path)
        _ = try ControlCenterFiles.apply(create, backupRoot: root)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == absent.path)
        #expect(try String(contentsOf: absent, encoding: .utf8) == "created")
    }

    private func makeDirectory() throws -> URL {
        let directory = controlCenterTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
