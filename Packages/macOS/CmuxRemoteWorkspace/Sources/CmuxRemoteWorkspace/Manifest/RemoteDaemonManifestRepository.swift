public import CmuxCore
public import Foundation
internal import CmuxSettings
internal import CryptoKit

/// Validates locally cached and bundled daemon artifacts without network acquisition.
///
/// The embedded checksum remains authoritative. Missing artifacts are reported to
/// the caller so the user can explicitly build or install the remote prerequisite.
public struct RemoteDaemonManifestRepository: Sendable {

    // FileManager is documented thread-safe for these path-based operations;
    // scoping the escape hatch to the one property beats `@unchecked
    // Sendable` on the type.
    nonisolated(unsafe) let fileManager: FileManager
    private let homeDirectory: URL
    let bundledAssetsDirectory: URL?

    /// Creates a repository rooted at `homeDirectory`'s cmux state cache.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem seam.
    ///   - homeDirectory: The user's home directory; composition roots pass
    ///     `FileManager.default.homeDirectoryForCurrentUser` so the app and
    ///     CLI agree on the cache path independently of `$HOME` overrides.
    ///   - bundledAssetsDirectory: Locally bundled compressed daemon resources;
    ///     nil means no bundled artifact is available.
    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL,
        bundledAssetsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.bundledAssetsDirectory = bundledAssetsDirectory
    }

    /// The cache path for one version/platform daemon binary
    /// (`<state>/remote-daemons/<version>/<goOS>-<goArch>/cmuxd-remote`),
    /// creating the cache root directory if needed.
    ///
    /// Cached under the non-TCC cmux state directory (matching the CLI's
    /// `remoteDaemonCacheURL`) rather than Application Support, so the
    /// separately-signed CLI can read it on `cmux ssh` without tripping the
    /// macOS Sequoia "access data from other apps" prompt
    /// (https://github.com/manaflow-ai/cmux/issues/5146).
    public func cachedBinaryURL(version: String, goOS: String, goArch: String) throws -> URL {
        try cacheRoot()
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    /// Returns the cached binary for `entry` when it exists, matches the
    /// entry's checksum, and is executable; removes (and reports `nil` for) a
    /// stale or non-executable cache entry. Throws when the cache cannot be
    /// read.
    public func validatedCachedBinary(entry: WorkspaceRemoteDaemonManifest.Entry, version: String) throws -> URL? {
        let cacheURL = try cachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        let fileSize = (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else {
            try? fileManager.removeItem(at: cacheURL)
            return nil
        }
        let cachedSHA = try sha256Hex(forFile: cacheURL)
        if cachedSHA == entry.sha256.lowercased(),
           fileManager.isExecutableFile(atPath: cacheURL.path) {
            return cacheURL
        }
        try? fileManager.removeItem(at: cacheURL)
        return nil
    }

    /// Installs one checksum-verified bundled artifact into the local cache.
    ///
    /// - Parameters:
    ///   - entry: Embedded checksum and platform of the local artifact.
    ///   - version: Versioned cache namespace.
    /// - Returns: The local executable, or nil when no resources were bundled.
    /// - Throws: A filesystem, decompression, or checksum verification failure.
    public func bundledBinary(
        entry: WorkspaceRemoteDaemonManifest.Entry,
        version: String
    ) throws -> URL? {
        try installBundledBinary(entry: entry, version: version)
    }

    private func cacheRoot() throws -> URL {
        let cacheRoot = CmuxStateDirectory.url(homeDirectory: homeDirectory)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
