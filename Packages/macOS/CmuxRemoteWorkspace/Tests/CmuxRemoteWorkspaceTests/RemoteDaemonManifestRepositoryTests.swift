import CmuxCore
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace


@Suite("RemoteDaemonManifestRepository")
struct RemoteDaemonManifestRepositoryTests {
    private func makeRepository(home: URL) -> RemoteDaemonManifestRepository {
        RemoteDaemonManifestRepository(homeDirectory: home)
    }

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-manifest-repo-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeEntry(port: Int, assetPath: String, sha256: String) -> WorkspaceRemoteDaemonManifest.Entry {
        let json = """
        {
          "goOS": "linux",
          "goArch": "amd64",
          "assetName": "cmuxd-remote-linux-amd64",
          "downloadURL": "http://127.0.0.1:\(port)\(assetPath)",
          "sha256": "\(sha256)"
        }
        """
        return try! JSONDecoder().decode(WorkspaceRemoteDaemonManifest.Entry.self, from: Data(json.utf8))
    }


    @Test("the cache path is versioned by platform under the cmux state directory")
    func cachePathShape() throws {
        let home = try temporaryHome()
        let url = try makeRepository(home: home).cachedBinaryURL(version: "0.62.0", goOS: "linux", goArch: "arm64")
        #expect(url.path == home.path + "/.local/state/cmux/remote-daemons/0.62.0/linux-arm64/cmuxd-remote")
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/state/cmux/remote-daemons").path,
            isDirectory: &isDirectory
        )
        #expect(rootExists && isDirectory.boolValue, "cache root is created eagerly")
    }


    @Test("validatedCachedBinary returns a matching executable cache hit and clears a stale one")
    func validatedCachedBinary() throws {
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let binary = Data("cached daemon".utf8)
        let entry = makeEntry(port: 1, assetPath: "/unused", sha256: sha256Hex(binary))
        let cacheURL = try repository.cachedBinaryURL(version: "0.99.0", goOS: "linux", goArch: "amd64")

        // Missing: nil.
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == nil)

        // Present + matching + executable: hit.
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary.write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.path)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == cacheURL)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path), "a valid hit is not deleted")

        // Present + executable but empty: treated as corrupt and removed.
        try Data().write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.path)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        // Present + stale bytes: removed, nil.
        try binary.write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.path)
        try Data("tampered".utf8).write(to: cacheURL)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
