import AppKit
import CmuxControlCenter
import Foundation

extension ControlCenterCoordinator {
    func vaultIndex() -> SessionIndexStore {
        if let sessionIndex { return sessionIndex }
        let index = SessionIndexStore(configStore: settingsRuntime?.jsonStore)
        sessionIndex = index
        return index
    }

    func searchSessions(_ query: String) async {
        do { try await findSessions(query) }
        catch { self.error = error.localizedDescription }
    }

    func findSessions(_ query: String) async throws {
        let index = vaultIndex()
        let result: SessionIndexStore.SearchOutcome
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = await index.loadRecentSessions(limitPerAgent: 200)
        } else {
            result = await index.searchAllSessions(rawQuery: "agent:omp \(query)")
        }
        try Task.checkCancellation()
        let entries = result.entries.filter { $0.agent.rawValue == "omp" }
        sessions = entries.map { entry in
            let id = sessionTargetIDs[entry.id] ?? UUID()
            sessionTargetIDs[entry.id] = id
            return ControlCenterTarget(
                id: id,
                name: entry.title,
                kind: .session,
                path: entry.cwd ?? "",
                sessionID: entry.sessionId,
                sessionFile: entry.fileURL?.path
            )
        }
        if !result.errors.isEmpty {
            throw ControlCenterHostError.blocked(result.errors.joined(separator: "\n"))
        }
    }

    func logicalDirectory(_ raw: String, create: Bool = false) throws -> String {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw ControlCenterHostError.blocked("Choose an absolute directory path.")
        }
        // Do not resolve symlinks: OMP's --cwd and the receipt keep the user's logical path.
        var names: [String] = []
        for component in expanded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !names.isEmpty { names.removeLast() }; continue }
            names.append(String(component))
        }
        let path = "/" + names.joined(separator: "/")
        let manager = FileManager.default
        let physical = canonicalPath(path)
        if physical.hasPrefix("/Volumes/") {
            let volume = "/" + physical.split(separator: "/").prefix(2).joined(separator: "/")
            let mounted = manager.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
            guard mounted.contains(where: { canonicalPath($0.path) == volume }) else {
                throw ControlCenterHostError.blocked("The required volume is not mounted: \(volume)")
            }
        }
        var current = "/"
        let components = (path as NSString).pathComponents.dropFirst()
        for component in components {
            current = (current as NSString).appendingPathComponent(component)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: current, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw ControlCenterHostError.blocked("Not a directory: \(current)") }
            } else {
                if (try? manager.destinationOfSymbolicLink(atPath: current)) != nil {
                    throw ControlCenterHostError.blocked("A symlink target or mounted volume is unavailable: \(current)")
                }
                guard create else {
                    throw ControlCenterHostError.blocked("Directory or mounted volume is unavailable: \(current)")
                }
                try manager.createDirectory(atPath: current, withIntermediateDirectories: false)
            }
        }
        guard manager.isReadableFile(atPath: path), manager.isExecutableFile(atPath: path) else {
            throw ControlCenterHostError.blocked("Directory is not accessible: \(path)")
        }
        return path
    }

    func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func ompExecutable() throws -> URL {
        let configured = connection.ompExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String]
        if !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw ControlCenterHostError.blocked("OMP executable must be an absolute installed path.") }
            candidates = [path]
        } else {
            candidates = AgentExecutableResolver().resolvedSearchDirectories().map { ($0 as NSString).appendingPathComponent("omp") }
        }
        for path in candidates {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let components = resolved.pathComponents
            guard !components.contains(".venv"),
                  !components.contains(".build"), !components.contains("DerivedData"),
                  !components.contains("Work"), !components.contains("work") else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { continue }
            if let resources = Bundle.main.resourceURL, resolved.path.hasPrefix(resources.path + "/") { continue }
            return URL(fileURLWithPath: path)
        }
        throw ControlCenterHostError.blocked("No independent installed OMP executable was found. Set its absolute path in Connection.")
    }

    func tabManagers() -> [TabManager] {
        guard let app = AppDelegate.shared else { return [] }
        var managers = app.allMainWindowTabManagersForDebug()
        if let manager = app.tabManager, !managers.contains(where: { $0 === manager }) { managers.append(manager) }
        return managers
    }

    func currentManager() throws -> TabManager {
        guard let manager = AppDelegate.shared?.tabManager,
              !manager.isFinalizedForWindowClose else {
            throw ControlCenterHostError.blocked("Open a cmux window before launching a target.")
        }
        return manager
    }

    func indexedSession(_ target: ControlCenterTarget) async throws -> SessionEntry {
        guard let id = target.sessionID, !id.isEmpty else { throw ControlCenterHostError.blocked("Choose one exact indexed session.") }
        let outcome = await vaultIndex().searchAllSessions(rawQuery: "agent:omp \(id)")
        try checkCancellation()
        var entries = outcome.entries.filter { $0.agent.rawValue == "omp" && $0.sessionId == id }
        if entries.isEmpty {
            let recent = await vaultIndex().loadRecentSessions(limitPerAgent: 500)
            entries = recent.entries.filter { $0.agent.rawValue == "omp" && $0.sessionId == id }
        }
        guard entries.count == 1, let entry = entries.first, let file = entry.fileURL else {
            throw ControlCenterHostError.blocked("Session is missing or ambiguous in the current Vault index. Search again; no session was started.")
        }
        if let expected = target.sessionFile, canonicalPath(expected) != canonicalPath(file.path) {
            throw ControlCenterHostError.blocked("The indexed session moved. Select its current search result before resuming.")
        }
        return entry
    }

    nonisolated static func checkSessionFile(_ file: URL, sessionID: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var pending = Data()
        var headerChecked = false
        var latestTransfer: String?
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            var cursor = pending.startIndex
            while let end = pending[cursor...].firstIndex(of: 10) {
                let line = pending[cursor..<end]
                cursor = pending.index(after: end)
                guard !line.isEmpty else { continue }
                guard let value = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw ControlCenterHostError.blocked("The indexed session journal is invalid.")
                }
                if !headerChecked {
                    guard value["type"] as? String == "session", value["id"] as? String == sessionID else {
                        throw ControlCenterHostError.blocked("The indexed file no longer identifies this session.")
                    }
                    headerChecked = true
                }
                if value["type"] as? String == "custom_message", value["customType"] as? String == "session-transfer" {
                    latestTransfer = (value["details"] as? [String: Any])?["kind"] as? String
                }
            }
            pending.removeSubrange(pending.startIndex..<cursor)
            guard pending.count <= 8_388_608 else { throw ControlCenterHostError.blocked("Session journal contains an oversized incomplete record.") }
        }
        guard headerChecked, pending.isEmpty else { throw ControlCenterHostError.blocked("Session journal is incomplete; resume is blocked.") }
        guard latestTransfer != "departed" else { throw ControlCenterHostError.blocked("This session moved to another machine. Resuming it would create a copy, so it is blocked.") }
    }

    func focusOrResume(_ target: ControlCenterTarget) async throws -> (UUID?, String) {
        let entry = try await indexedSession(target)
        _ = await SharedLiveAgentIndex.shared.indexRefreshingNow()
        try checkCancellation()
        for manager in tabManagers() {
            if let active = SessionEntryResumeCoordinator.activeTarget(for: entry, tabManager: manager),
               SessionEntryResumeCoordinator.focusIfActive(entry, tabManager: manager) {
                switch active {
                case .workspace(let id, _): return (id, "Focused the existing exact session.")
                case .dock(let panelID):
                    let dock = DockSplitStore.liveStore(containingPanel: panelID)
                    return (dock?.scope == .workspace ? dock?.workspaceId : nil, "Focused the existing exact session in its Dock.")
                }
            }
        }
        guard let cwd = entry.cwd, !cwd.isEmpty, let file = entry.fileURL else {
            throw ControlCenterHostError.blocked("The indexed session has no working directory or journal.")
        }
        let logical = try logicalDirectory(canonicalPath(target.path) == canonicalPath(cwd) ? target.path : cwd)
        let sessionID = entry.sessionId
        let inspection = Task.detached(priority: .userInitiated) {
            try Self.checkSessionFile(file, sessionID: sessionID)
        }
        try await withTaskCancellationHandler {
            try await inspection.value
        } onCancel: {
            inspection.cancel()
        }
        let executable = try ompExecutable()
        let data = try await ControlCenterOMPProbe().capture(
            executable: executable,
            arguments: ["session", "lease", "--json", "--", entry.sessionId],
            directory: dataDirectory()
        )
        try checkCancellation()
        struct Lease: Decodable { let held: [String]; let unknown: [String] }
        let lease: Lease
        do { lease = try JSONDecoder().decode(Lease.self, from: data) }
        catch { throw ControlCenterHostError.blocked("OMP returned an unknown lease response. No session was started.") }
        guard lease.held.isEmpty, lease.unknown.isEmpty else {
            throw ControlCenterHostError.blocked("This session is held elsewhere or its ownership is unknown. No copy was created.")
        }
        let manager = try currentManager()
        guard let claim = AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(kind: "omp", sessionId: entry.sessionId) else {
            throw ControlCenterHostError.blocked("This session already has a pending resume. Wait for it rather than launching a copy.")
        }
        let command = [executable.path, "--cwd", logical, "--session", file.path].map(SessionEntry.shellQuote).joined(separator: " ")
        guard let workspace = manager.addWorkspaceIfActive(
            title: target.name,
            workingDirectory: logical,
            initialTerminalInput: TerminalStartupTypedShellCommand().typedInput(posixCommand: command) + "\n",
            initialTerminalStartupRestoreAgent: entry.resumeLaunch?.startupRestoreAgent,
            inheritWorkingDirectory: false
        ) else {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "omp", sessionId: entry.sessionId, claim: claim)
            throw ControlCenterHostError.blocked("The workspace could not be created. No resume was launched.")
        }
        return (workspace.id, "Submitted exact indexed OMP journal to a new workspace (not --continue). Launch completion is not yet observed.")
    }
}
