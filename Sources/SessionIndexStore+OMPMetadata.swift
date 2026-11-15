import CmuxAgentSessionStore
import CmuxFoundation
import CryptoKit
import Darwin
import Foundation

/// Process-wide discovery cache. Admission still uses the live exact-journal path.
actor OMPMetadataCoordinator {
    static let shared = OMPMetadataCoordinator(databaseURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", isDirectory: true)
        .appendingPathComponent("Vault/OMPMetadata/metadata.sqlite3"))

    struct Source: Sendable {
        let registration: CmuxVaultAgentRegistration
        let root: URL
        let canonicalRoot: String
        let namespace: String

        init(registration: CmuxVaultAgentRegistration) throws {
            guard let directory = registration.sessionDirectory, !directory.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.registration = registration
            root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
            canonicalRoot = root.resolvingSymlinksInPath().path
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var identity = try encoder.encode(registration)
            identity.append(Data("\n\(root.path)\n\(canonicalRoot)".utf8))
            namespace = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        }

        var isCurrent: Bool { root.resolvingSymlinksInPath().path == canonicalRoot }
    }

    private let databaseURL: URL
    private var database: OMPSessionMetadataIndex?
    private var jobs: [String: Task<Void, any Error>] = [:]
    private var pending: [String: RecursivePathChange] = [:]
    private var activated: Set<String> = []
    private var watchers: [String: RecursivePathWatcher] = [:]
    private var watchTasks: [String: Task<Void, Never>] = [:]

    init(databaseURL: URL) { self.databaseURL = databaseURL }

    deinit {
        for task in watchTasks.values { task.cancel() }
        for watcher in watchers.values { Task { await watcher.stop() } }
    }

    func stopWatching() async {
        let previousJobs = Array(jobs.values)
        for task in previousJobs { task.cancel() }
        for task in watchTasks.values { task.cancel() }
        let previous = Array(watchers.values)
        watchers.removeAll()
        watchTasks.removeAll()
        pending.removeAll()
        activated.removeAll()
        for watcher in previous { await watcher.stop() }
        for job in previousJobs { _ = try? await job.value }
    }

    private func index() throws -> OMPSessionMetadataIndex {
        if let database { return database }
        let next = try OMPSessionMetadataIndex(databaseURL: databaseURL)
        database = next
        return next
    }

    func search(source: Source, query: String, cwd: String?, offset: Int, limit: Int) async throws -> [OMPSessionMetadataRecord] {
        let database = try index()
        if try await database.isInitialized(namespace: source.namespace) == false {
            repeat {
                try await reconcile(source: source)
            } while try await !database.isInitialized(namespace: source.namespace)
        } else if activated.insert(source.namespace).inserted || (watchers[source.namespace] == nil && jobs[source.namespace] == nil) {
            // Reopen returns the durable snapshot without awaiting the startup scan.
            Task { try? await self.reconcile(source: source) }
        }
        try Task.checkCancellation()
        let records = try await database.search(namespace: source.namespace, query: query, cwd: cwd, offset: offset, limit: limit)
        guard source.isCurrent else { return [] }
        return records
    }

    /// Full reconciliation is shared by cold readers, startup and directory events.
    func reconcile(source: Source) async throws {
        if let job = jobs[source.namespace] {
            try await job.value
            return
        }
        activated.insert(source.namespace)
        pending[source.namespace] = RecursivePathChange(paths: [], requiresFullRescan: true)
        let job = Task { try await self.drain(source: source) }
        jobs[source.namespace] = job
        try await job.value
    }

    private func changed(_ change: RecursivePathChange, source: Source) {
        if let previous = pending[source.namespace] {
            pending[source.namespace] = RecursivePathChange(
                paths: Array(Set(previous.paths + change.paths)),
                requiresFullRescan: previous.requiresFullRescan || change.requiresFullRescan
            )
        } else { pending[source.namespace] = change }
        guard jobs[source.namespace] == nil else { return }
        jobs[source.namespace] = Task { try await self.drain(source: source) }
    }

    private func drain(source: Source) async throws {
        defer {
            jobs.removeValue(forKey: source.namespace)
            if pending[source.namespace] != nil, !Task.isCancelled {
                jobs[source.namespace] = Task { try await self.drain(source: source) }
            }
        }
        if watchers[source.namespace] == nil {
            let paths = Array(Set([source.root.path, source.canonicalRoot, source.root.deletingLastPathComponent().path]))
            if let watcher = await RecursivePathWatcher(paths: paths, eventFilter: { change in
                change.paths.contains { Self.eventKind(path: $0, source: source) != .ignored }
            }) {
                guard !Task.isCancelled else { await watcher.stop(); return }
                watchers[source.namespace] = watcher
                watchTasks[source.namespace] = Task { [weak self] in
                    for await change in watcher.pathEvents {
                        guard !Task.isCancelled else { return }
                        await self?.changed(change, source: source)
                    }
                }
            }
        }
        let database = try index()
        if let change = pending.removeValue(forKey: source.namespace) {
            guard source.isCurrent else { return }
            let previous = try await database.records(namespace: source.namespace)
            let worker = Task.detached(priority: .utility) {
                try Self.scan(source: source, previous: previous, change: change)
            }
            let delta = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard source.isCurrent else { return }
            try await database.apply(namespace: source.namespace, upserts: delta.upserts, removing: delta.removing, completedScan: delta.completedScan)
        }
    }

    private struct Delta: Sendable {
        var upserts: [OMPSessionMetadataRecord] = []
        var removing: [String] = []
        var completedScan = false
    }

    private enum EventKind: Equatable { case ignored, file, full }

    /// Lexical only: FSEvents calls this before throttling, without stat/realpath work.
    private static func eventKind(path: String, source: Source) -> EventKind {
        for root in [source.root.path, source.canonicalRoot] {
            if path == root || root.hasPrefix(path + "/") { return .full }
            guard path.hasPrefix(root + "/") else { continue }
            let components = path.dropFirst(root.count + 1).split(separator: "/")
            guard (1...2).contains(components.count), !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            if components.last?.hasSuffix(".jsonl") == true { return .file }
            // Only immediate project-bucket directory changes can add/remove
            // eligible journals. Deeper task/artifact directories are irrelevant.
            if components.count == 1 { return .full }
        }
        return .ignored
    }

    private static func scan(source: Source, previous: [OMPSessionMetadataRecord], change: RecursivePathChange) throws -> Delta {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.journalPath, $0) })
        var full = change.requiresFullRescan
        var urls: [URL] = []
        if !full {
            for path in change.paths {
                switch eventKind(path: path, source: source) {
                case .ignored: continue
                case .full: full = true
                case .file:
                    let normalizedPath = path.hasPrefix(source.canonicalRoot + "/")
                        ? source.root.path + String(path.dropFirst(source.canonicalRoot.count))
                        : path
                    let url = URL(fileURLWithPath: normalizedPath).standardizedFileURL
                    if eligible(url, source: source) { urls.append(url) }
                }
                if full { break }
            }
        }
        if full { urls = try candidates(source: source) }
        var result = Delta(completedScan: full)
        let present = Set(urls.map(\.path))
        if full { result.removing = old.keys.filter { !present.contains($0) } }
        for url in urls {
            try Task.checkCancellation()
            guard let stamp = try stamp(url) else {
                if old[url.path] != nil { result.removing.append(url.path) }
                continue
            }
            guard old[url.path]?.fingerprint != stamp.fingerprint else { continue }
            let metadata = try SessionIndexStore.ompIndexedMetadata(url: url, registration: source.registration)
            // Do not publish a torn read, even when an append/atomic replace races us.
            guard try Self.stamp(url)?.fingerprint == stamp.fingerprint else {
                throw CocoaError(.fileReadUnknown)
            }
            if let metadata {
                result.upserts.append(OMPSessionMetadataRecord(
                    journalPath: url.path, sessionID: metadata.id, title: metadata.title,
                    cwd: metadata.cwd, branch: metadata.branch, modifiedAt: stamp.modified,
                    fingerprint: stamp.fingerprint
                ))
            } else if old[url.path] != nil { result.removing.append(url.path) }
        }
        try Task.checkCancellation()
        return result
    }

    private static func eligible(_ url: URL, source: Source) -> Bool {
        guard url.pathExtension == "jsonl", !url.lastPathComponent.hasPrefix(".") else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.path == source.canonicalRoot
            || (parent.deletingLastPathComponent().path == source.canonicalRoot && !parent.lastPathComponent.hasPrefix("."))
    }

    private static func candidates(source: Source) throws -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let children = try fm.contentsOfDirectory(at: source.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var result: [URL] = []
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                guard child.resolvingSymlinksInPath().deletingLastPathComponent().path == source.canonicalRoot else { continue }
                for url in try fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) where eligible(url, source: source) {
                    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.append(url) }
                }
            } else if values.isRegularFile == true, eligible(child, source: source) { result.append(child) }
        }
        return result
    }

    private static func stamp(_ url: URL) throws -> (fingerprint: String, modified: Date)? {
        var status = stat()
        guard stat(url.path, &status) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return (
            "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)",
            Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
    }
}

extension SessionIndexStore {
    func searchOMPMetadata(query: String, cwd: String? = nil, offset: Int, limit: Int) async -> SearchOutcome {
        let registry = await registryProvider(cwd)
        guard !Task.isCancelled, registry.historyConfigurationIsCurrent,
              registry.isHistoryEnabled(for: "omp"), let registration = registry.registration(id: "omp") else {
            return SearchOutcome(entries: [], errors: [])
        }
        let bag = ErrorBag()
        let entries = await Self.loadOMPMetadataEntries(registration: registration, query: query, cwd: cwd, offset: offset, limit: limit, errorBag: bag)
        guard !Task.isCancelled, registry.historyConfigurationIsCurrent else { return SearchOutcome(entries: [], errors: []) }
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }

    nonisolated static func loadOMPMetadataEntries(registration: CmuxVaultAgentRegistration, query: String, cwd: String?, offset: Int, limit: Int, errorBag: ErrorBag) async -> [SessionEntry] {
        do {
            let source = try await Task.detached(priority: .utility) { try OMPMetadataCoordinator.Source(registration: registration) }.value
            let records = try await OMPMetadataCoordinator.shared.search(source: source, query: query, cwd: cwd, offset: offset, limit: limit)
            return records.map { record in
                SessionEntry(
                    id: "omp:\(record.sessionID):\(record.journalPath)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: record.sessionID, title: record.title, cwd: record.cwd,
                    gitBranch: record.branch, pullRequest: nil, modified: record.modifiedAt,
                    fileURL: URL(fileURLWithPath: record.journalPath), specifics: .registered(registration)
                )
            }
        } catch is CancellationError { return [] }
        catch { errorBag.addSafe(diagnostic: "OMP metadata: \(error.localizedDescription)"); return [] }
    }
}
