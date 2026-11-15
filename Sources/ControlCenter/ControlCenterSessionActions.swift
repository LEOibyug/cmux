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

    func refreshSessionSources() async {
        let registry = await SessionIndexStore.vaultAgentRegistry(workingDirectory: nil)
        sessionSources = SessionIndexStore.agentOrder(registry: registry).agents
    }

    func sessionSource(_ agentID: String) async throws -> SessionAgent {
        await refreshSessionSources()
        try Task.checkCancellation()
        guard let agent = sessionSources.first(where: { $0.rawValue == agentID }) else {
            throw ControlCenterHostError.blocked("Session history is disabled or unavailable for source \(agentID). Enable it in Vault settings before searching or opening its sessions.")
        }
        return agent
    }

    func searchSessions(_ query: String) async {
        let source = sessionSourceID
        let generation = sessionSearchGeneration + 1
        do { try await findSessions(query, agentID: source, searchContent: source != "omp") }
        catch is CancellationError {}
        catch {
            if sessionSourceID == source, sessionSearchGeneration == generation { self.error = error.localizedDescription }
        }
    }

    func findSessions(_ query: String, agentID: String, searchContent: Bool = true) async throws {
        sessionSearchGeneration += 1
        let generation = sessionSearchGeneration
        sessions = []
        sessionResultsSourceID = agentID
        let agent = try await sessionSource(agentID)
        guard generation == sessionSearchGeneration else { throw CancellationError() }
        let indexedOMP = agentID == "omp" && !searchContent
        let result: SessionIndexStore.SearchOutcome
        if indexedOMP {
            result = await vaultIndex().searchOMPMetadata(query: query, offset: 0, limit: 500)
        } else {
            result = await vaultIndex().searchSessions(query: searchContent ? query : "", scope: .agent(agent), offset: 0, limit: 500)
        }
        try Task.checkCancellation()
        guard generation == sessionSearchGeneration else { throw CancellationError() }
        error = nil
        let entries = result.entries.filter { entry in
            guard entry.agent.rawValue == agentID else { return false }
            if indexedOMP || searchContent || query.isEmpty { return true }
            return [entry.title, entry.cwd ?? "", entry.sessionId].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let sessionCounts = Dictionary(grouping: entries, by: \.sessionId).mapValues(\.count)
        sessions = entries.map { entry in
            var target = ControlCenterTarget(
                name: entry.title,
                kind: .session,
                path: entry.cwd ?? "",
                sessionID: entry.sessionId,
                sessionFile: entry.fileURL?.path,
                agentID: entry.agent.rawValue
            )
            if sessionCounts[entry.sessionId] == 1, let identity = target.sessionIdentity {
                target.id = sessionTargetIDs[identity] ?? target.id
                sessionTargetIDs[identity] = target.id
            }
            return target
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
        let agent = try await sessionSource(target.agentID)
        if target.agentID == "omp" {
            guard let path = target.sessionFile else {
                throw ControlCenterHostError.blocked("Choose an exact indexed OMP journal from session history. No session was started.")
            }
            let entry = try await vaultIndex().exactOMPSession(sessionID: id, journal: URL(fileURLWithPath: path))
            try checkCancellation()
            return entry
        }
        let outcome = await vaultIndex().searchSessions(query: id, scope: .agent(agent), offset: 0, limit: 500)
        try checkCancellation()
        guard outcome.errors.isEmpty else { throw ControlCenterHostError.blocked(outcome.errors.joined(separator: "\n")) }
        var entries = outcome.entries.filter { $0.agent.rawValue == target.agentID && $0.sessionId == id }
        if entries.isEmpty {
            let recent = await vaultIndex().searchSessions(query: "", scope: .agent(agent), offset: 0, limit: 500)
            try checkCancellation()
            guard recent.errors.isEmpty else { throw ControlCenterHostError.blocked(recent.errors.joined(separator: "\n")) }
            entries = recent.entries.filter { $0.agent.rawValue == target.agentID && $0.sessionId == id }
        }
        guard entries.count == 1, let entry = entries.first else {
            throw ControlCenterHostError.blocked("Session is missing or ambiguous in the current Vault index. Search again; no session was started.")
        }
        return entry
    }

    nonisolated static func checkSessionFile(_ file: URL, sessionID: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var pending = Data()
        var headerChecked = false
        var titleSlotSeen = false
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
                    if !titleSlotSeen, value["type"] as? String == "title" {
                        titleSlotSeen = true
                        continue
                    }
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

    func observeOMPLaunch(_ launch: ControlCenterOMPLaunch, workspace: Workspace) async throws -> String {
        guard let terminal = workspace.panels.values.lazy.compactMap({ $0 as? TerminalPanel }).first else {
            throw ControlCenterHostError.blocked("The OMP workspace has no terminal. No launched process was observed.")
        }
        terminal.surface.requestBackgroundSurfaceStartIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try checkCancellation()
            guard workspace.panels[terminal.id] === terminal else {
                throw ControlCenterHostError.blocked("The OMP terminal was closed before launch could be observed.")
            }
            if terminal.surface.renderHealth == .shellExited {
                throw ControlCenterHostError.blocked("OMP exited before launch could be observed. Its workspace was left open for inspection.")
            }
            if let processID = terminal.surface.foregroundProcessID() {
                let workspaceID = workspace.id
                let surfaceID = terminal.surface.id
                let observed = await Task.detached(priority: .userInitiated) {
                    launch.runningProcessID(foregroundID: processID, workspaceID: workspaceID, surfaceID: surfaceID)
                }.value
                try checkCancellation()
                if let observed {
                    return "Observed OMP process \(observed) in logical directory \(launch.directory)" +
                        (launch.journal.map { " with exact indexed journal \($0.path) (not --continue)." } ?? ".")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlCenterHostError.blocked("Timed out waiting to observe OMP in workspace \(workspace.id.uuidString). The workspace was left open; an empty shell is not a successful launch.")
    }

    func focusOrResume(_ target: ControlCenterTarget) async throws -> (UUID?, String) {
        let entry = try await indexedSession(target)
        let liveIndex = await SharedLiveAgentIndex.shared.indexRefreshingNow()
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
        if entry.agent.rawValue != "omp" {
            guard let launch = entry.resumeLaunch else {
                throw ControlCenterHostError.blocked("This source does not provide a resumable launch for the indexed session.")
            }
            if let cwd = launch.workingDirectory { _ = try logicalDirectory(cwd) }
            let manager = try currentManager()
            let kind = entry.agent.rawValue
            let claim: AgentResumeLaunchGuard.Claim?
            switch launch.strategy {
            case .restoreVerb:
                claim = nil
            case .legacyCommand:
                guard let acquired = AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(kind: kind, sessionId: entry.sessionId) else {
                    throw ControlCenterHostError.blocked("This session already has a pending resume. Wait for it rather than launching a copy.")
                }
                claim = acquired
            }
            guard let workspace = manager.addWorkspaceIfActive(
                title: target.name,
                workingDirectory: launch.workingDirectory,
                initialTerminalInput: launch.initialInput,
                initialTerminalStartupRestoreAgent: launch.startupRestoreAgent,
                inheritWorkingDirectory: false
            ) else {
                if let claim {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: kind, sessionId: entry.sessionId, claim: claim)
                }
                throw ControlCenterHostError.blocked("The workspace could not be created. No resume was launched.")
            }
            return (workspace.id, "Submitted the exact indexed \(entry.agent.displayName) session through its Vault resume adapter. Launch admission and completion are not yet observed.")
        }
        guard let liveIndex, liveIndex.isComplete else {
            throw ControlCenterHostError.blocked("Fresh OMP ownership evidence is unavailable or incomplete. No session was started.")
        }
        let sessionID = entry.sessionId
        guard let cwd = entry.cwd, !cwd.isEmpty, let file = entry.fileURL else {
            throw ControlCenterHostError.blocked("The indexed session has no working directory or journal.")
        }
        let logical = try logicalDirectory(cwd)
        let launchKey = "omp-session:\(entry.sessionId):\(canonicalPath(file.path))"
        let launch = ControlCenterOMPLaunch(executable: try ompExecutable(), directory: logical, journal: file)
        if let workspaceID = openedTargets[launchKey] {
            for manager in tabManagers() {
                if let workspace = manager.tabs.first(where: { $0.id == workspaceID }) {
                    manager.focusTab(workspaceID)
                    return (workspaceID, try await observeOMPLaunch(launch, workspace: workspace))
                }
            }
        }
        let inspection = Task.detached(priority: .userInitiated) {
            try Self.checkSessionFile(file, sessionID: sessionID)
        }
        try await withTaskCancellationHandler {
            try await inspection.value
        } onCancel: {
            inspection.cancel()
        }
        let executable = launch.executable
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
        let ownership = Task.detached(priority: .userInitiated) {
            liveIndex.liveSessionOwner(
                kind: "omp", sessionID: sessionID,
                processArgumentsProvider: { CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0) }
            ) != nil
        }
        guard !(await ownership.value) else {
            throw ControlCenterHostError.blocked("The exact OMP session already has a live owner outside the available panes. No copy was created.")
        }
        try checkCancellation()
        let manager = try currentManager()
        guard let claim = AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(kind: "omp", sessionId: entry.sessionId) else {
            throw ControlCenterHostError.blocked("This session already has a pending resume. Wait for it rather than launching a copy.")
        }
        guard let workspace = manager.addWorkspaceIfActive(
            title: target.name,
            workingDirectory: logical,
            initialTerminalCommand: launch.initialCommand,
            inheritWorkingDirectory: false,
            eagerLoadTerminal: true
        ) else {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "omp", sessionId: entry.sessionId, claim: claim)
            throw ControlCenterHostError.blocked("The workspace could not be created. No resume was launched.")
        }
        openedTargets[launchKey] = workspace.id
        return (workspace.id, try await observeOMPLaunch(launch, workspace: workspace))
    }
}
