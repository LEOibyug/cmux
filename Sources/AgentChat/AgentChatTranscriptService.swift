import CMUXAgentLaunch
import CmuxAgentChat
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Tracks local agent sessions and serves on-demand transcript history and search.
@MainActor
final class AgentChatTranscriptService {

    let registry: AgentChatSessionRegistry
    let resolver: AgentChatTranscriptResolver
    private var tailers: [String: AgentChatTranscriptTailer] = [:]
    private let now: () -> Date
    private var didShutdown = false
    /// Sessions whose transcript could not be resolved cheaply; skipped until
    /// authoritative bindings arrive or an explicit history request retries.
    /// Hook delivery never runs Codex's recursive fallback scan.
    private var failedResolutions: Set<String> = []
    private let fallbackResolutionCoordinator: AgentChatFallbackTranscriptResolutionCoordinator
    private var endedListability = AgentChatEndedTranscriptListabilityCache()

    struct SidebarRevisionSnapshot: Sendable, Equatable {
        let liveRevision: UInt64
        let historyRevision: UInt64
    }

    private var sidebarLiveRevision: UInt64 = 0
    private var sidebarHistoryRevision: UInt64 = 0
    private var sidebarChangeObservers: [UUID: AsyncStream<SidebarRevisionSnapshot>.Continuation] = [:]

    var sidebarRevisionSnapshot: SidebarRevisionSnapshot {
        SidebarRevisionSnapshot(
            liveRevision: sidebarLiveRevision,
            historyRevision: sidebarHistoryRevision
        )
    }

    /// Typed observation owned by the authoritative session service. The
    /// newest revision pair subsumes any unread changes, so bursts coalesce
    /// without losing a history invalidation.
    func sidebarChanges() -> AsyncStream<SidebarRevisionSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            sidebarChangeObservers[id] = continuation
            continuation.yield(sidebarRevisionSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.sidebarChangeObservers[id] = nil }
            }
        }
    }

    private func publishSidebarChange(liveChanged: Bool, historyChanged: Bool) {
        guard liveChanged || historyChanged else { return }
        if liveChanged { sidebarLiveRevision &+= 1 }
        if historyChanged { sidebarHistoryRevision &+= 1 }
        let snapshot = sidebarRevisionSnapshot
        var terminatedIDs: [UUID] = []
        for (id, continuation) in sidebarChangeObservers {
            if case .terminated = continuation.yield(snapshot) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            sidebarChangeObservers[id] = nil
        }
    }


    /// Creates the service with a hook-store-backed registry.
    ///
    /// - Parameter resolver: Transcript path resolver.
    convenience init(resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver()) {
        self.init(registry: AgentChatSessionRegistry(), resolver: resolver)
    }

    /// Creates the service with explicit dependencies.
    ///
    /// - Parameters:
    ///   - registry: Session registry.
    ///   - resolver: Transcript path resolver.
    init(
        registry: AgentChatSessionRegistry,
        resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver(),
        now: @escaping () -> Date = { Date() },
        fallbackTranscriptPathResolver: AgentChatFallbackTranscriptResolutionCoordinator.Resolver? = nil,
        fallbackResolutionTimeout: Duration = .seconds(3)
    ) {
        self.registry = registry
        self.resolver = resolver
        self.now = now
        self.fallbackResolutionCoordinator = AgentChatFallbackTranscriptResolutionCoordinator(
            transcriptResolver: resolver,
            resolver: fallbackTranscriptPathResolver,
            timeout: fallbackResolutionTimeout
        )
        registry.onRecordChanged = { [weak self] record, previous in
            self?.handleRecordChange(record, previous: previous)
        }
        registry.onRecordRemoved = { [weak self] record in
            self?.handleRecordRemoval(record)
        }
    }

    /// Stops transcript watchers and local observation before application teardown.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        registry.onRecordChanged = nil
        registry.onRecordRemoved = nil
        let activeTailers = Array(tailers.values)
        tailers.removeAll()
        for tailer in activeTailers {
            Task { await tailer.stop() }
        }
        let observers = Array(sidebarChangeObservers.values)
        sidebarChangeObservers.removeAll()
        for continuation in observers {
            continuation.finish()
        }
    }


    /// A `(session, surface)` resume re-bind cmux authored during session
    /// restore, buffered until the service is live (restore can run before app
    /// setup assigns this service, so a direct call would be a silent no-op).
    private struct PendingResumeIntent {
        let sessionID: String
        let source: String
        let surfaceID: String?
        let workspaceID: String?
        let workingDirectory: String?
    }

    /// Resume re-binds recorded before ``start()`` wired the live instance.
    private static var pendingResumeIntents: [PendingResumeIntent] = []
    /// The started service, used to apply resume re-binds immediately once live.
    private static weak var liveInstance: AgentChatTranscriptService?
    static func isValidResumeSessionID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Records, from cmux's own authority, that it is resuming `sessionID` onto
    /// `surfaceID` (see
    /// ``AgentChatSessionRegistry/noteResumeInitiated(sessionID:source:surfaceID:workspaceID:workingDirectory:)``).
    /// Static so the restore path need not hold a service reference: before the
    /// service starts (restore can run first) the intent is buffered and flushed
    /// in ``start()``; after, it applies immediately.
    static func recordResumeIntent(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        guard isValidResumeSessionID(sessionID) else { return }
        if let live = liveInstance {
            live.noteResumeInitiated(
                sessionID: sessionID,
                source: source,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                workingDirectory: workingDirectory
            )
        } else {
            pendingResumeIntents.append(PendingResumeIntent(
                sessionID: sessionID,
                source: source,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                workingDirectory: workingDirectory
            ))
        }
    }

    /// Seeds the session registry from the on-disk hook stores. Call once at
    /// app startup. Hook events stay authoritative for state and transcripts;
    /// observe-floor scans later add live agent presence even before hooks fire.
    func start() {
        guard !didShutdown else { return }
        Self.liveInstance = self
        // Apply resume re-binds buffered before the service was wired. The seed
        // only creates records that don't already exist, so an intent applied
        // here is preserved (the seed skips it) and one applied after flips the
        // seeded `.ended` record to `.idle`: either order converges.
        let buffered = Self.pendingResumeIntents
        Self.pendingResumeIntents.removeAll()
        for intent in buffered {
            noteResumeInitiated(
                sessionID: intent.sessionID,
                source: intent.source,
                surfaceID: intent.surfaceID,
                workspaceID: intent.workspaceID,
                workingDirectory: intent.workingDirectory
            )
        }
        // Seeding reads+parses the hook-store JSON off the main actor; kick it
        // off and return. Live hook events also populate the registry, and the
        // seed converges within milliseconds.
        Task { [weak self] in await self?.registry.seedFromHookStores() }
    }

    /// Ingests one hook event (called from the socket dispatch path).
    ///
    /// - Parameter event: The hook event.
    func noteHookEvent(_ event: WorkstreamEvent) {
        guard !didShutdown else { return }
        let record = registry.noteHookEvent(event)
        // A session (re)starting or receiving a prompt is the bounded
        // retry point for a transcript that didn't exist at first sight.
        switch event.hookEventName {
        case .sessionStart, .userPromptSubmit:
            failedResolutions.remove(record.sessionID)
        default:
            break
        }
    }

    /// Immediately reflects user input on a terminal that is waiting for an
    /// agent answer. Hook delivery remains authoritative and reconciles the
    /// optimistic state on the next event.
    @discardableResult
    func noteExplicitInput(surfaceID: String, at: Date = Date()) -> Int {
        guard !didShutdown else { return 0 }
        return registry.noteUserInput(surfaceID: surfaceID, at: at)
    }

    /// Lists chat-capable sessions.
    ///
    /// - Parameter workspaceID: Workspace UUID string filter, or `nil`.
    /// - Returns: Wire descriptors, most recent first.
    func sessionDescriptors(workspaceID: String?) -> [ChatSessionDescriptor] {
        registry.sessions(workspaceID: workspaceID).map(\.descriptor)
    }

    /// Lists raw session records for callers that must validate live
    /// terminal bindings before exposing descriptors.
    ///
    /// - Parameter workspaceID: Workspace UUID string filter, or `nil`.
    /// - Returns: Matching records, most recent first.
    func sessionRecords(workspaceID: String?) -> [AgentChatSessionRecord] {
        registry.sessions(workspaceID: workspaceID)
    }

    /// Observe-floor detection: discover live codex/claude sessions from the
    /// process table (no hooks required) and fold them into the registry.
    /// Awaitable for tests/debug paths that need the updated registry before
    /// proceeding.
    func observeAgentProcesses() async {
        await registry.observeAgentProcesses()
    }

    /// Waits briefly for one coalesced observe-floor scan before a list pull.
    /// Returns false when the scan is still running at the deadline; the caller
    /// can return the current registry snapshot and let the scan push deltas.
    func observeAgentProcessesForListing(surfaceIDs: Set<UUID>?, waitUpTo timeout: Duration) async -> Bool {
        await registry.observeAgentProcessesForListing(surfaceIDs: surfaceIDs, waitUpTo: timeout)
    }

    /// The registry record for a session (send path needs the terminal
    /// binding).
    ///
    /// - Parameter sessionID: Raw session id.
    /// - Returns: The record, or `nil` when unknown.
    func sessionRecord(sessionID: String) -> AgentChatSessionRecord? {
        registry.record(sessionID: sessionID)
    }

    /// Whether an ended session can still serve history without expensive
    /// fallback scans. Live sessions stay visible before their JSONL exists;
    /// ended sessions with missing JSONL only open to an unrecoverable error.
    func hasBoundedReadableTranscript(_ record: AgentChatSessionRecord) -> Bool {
        resolver.boundedTranscriptPath(for: record) != nil
    }

    /// Whether an ended session should remain visible in the list. Claude can be
    /// checked cheaply from cwd/recorded path; Codex fallback scans its sessions
    /// tree, so Codex rows stay listable and resolve fallback history on open.
    func shouldListEndedSession(_ record: AgentChatSessionRecord) -> Bool {
        switch record.agentKind {
        case .codex:
            return true
        case .claude, .other:
            return endedListability.shouldList(record, resolver: resolver, now: now())
        }
    }

    /// Re-adopts one session's terminal bindings from the hook store; see
    /// ``AgentChatSessionRegistry/refreshBindingsFromHookStore(sessionID:)``.
    @discardableResult
    func refreshSessionBindings(sessionID: String) async -> AgentChatSessionRecord? {
        await registry.refreshBindingsFromHookStore(sessionID: sessionID)
    }

    /// cmux-authored resume re-bind (see
    /// ``AgentChatSessionRegistry/noteResumeInitiated(sessionID:source:surfaceID:workspaceID:workingDirectory:)``).
    /// Called from the session-restore path when cmux auto-resumes an agent, so
    /// the GUI reflects the live session immediately instead of waiting for a
    /// SessionStart hook the agent (codex) does not fire on resume.
    func noteResumeInitiated(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        guard !didShutdown else { return }
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: source,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory
        )
    }

    /// Re-stamps a session's stored workspace id to the workspace its surface
    /// currently lives in. cmux workspace ids regenerate on every Mac relaunch
    /// while surface ids are stable, so a session created before the last
    /// relaunch carries a stale `workspaceID`. The caller resolves the session's
    /// live surface to its current workspace and calls this so the seed and the
    /// live `descriptorChanged` pushes both scope to that workspace (the iOS
    /// reducer is workspace-scoped and rejects stale-workspace live updates).
    ///
    /// - Parameters:
    ///   - sessionID: The session to re-stamp.
    ///   - workspaceID: The surface's current workspace UUID string.
    func updateSessionWorkspace(sessionID: String, workspaceID: String) {
        registry.update(sessionID: sessionID) { $0.workspaceID = workspaceID }
    }

    /// Serves one history page, starting the session's tailer on demand.
    ///
    /// - Parameters:
    ///   - sessionID: The session to read.
    ///   - beforeSeq: Strict upper bound, or `nil` for the newest page.
    ///   - limit: Page size cap.
    /// - Returns: The page, or `nil` when the session or transcript is
    ///   unknown.
    func history(sessionID: String, beforeSeq: Int?, limit: Int) async -> ChatHistoryPage? {
        guard let record = registry.record(sessionID: sessionID) else { return nil }
        // A user opening the chat is the right moment to retry a previously
        // failed transcript resolution. Codex's recursive fallback is explicit
        // history work, so perform it off the main actor.
        failedResolutions.remove(sessionID)
        let tailer: AgentChatTranscriptTailer
        if let existing = tailers[sessionID] {
            tailer = existing
        } else {
            let resolver = resolver
            let initialPath = resolver.boundedTranscriptPath(for: record)
            let fallbackPath: String?
            if let initialPath {
                fallbackPath = initialPath
            } else {
                fallbackPath = await fallbackResolutionCoordinator.resolve(for: record)
            }
            guard let currentRecord = registry.record(sessionID: sessionID) else { return nil }
            failedResolutions.remove(sessionID)
            guard let resolvedTailer = ensureTailer(for: currentRecord, resolvePath: {
                resolver.boundedTranscriptPath(for: currentRecord) ?? fallbackPath
            }) else {
                return nil
            }
            tailer = resolvedTailer
        }
        await tailer.start()
        let page = await tailer.history(beforeSeq: beforeSeq, limit: limit)
        if record.title == nil, let title = await tailer.title {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        return page
    }

    /// Debug-socket dump of every registry record plus tailer liveness.
    func debugSessionDump() -> [[String: Any]] {
        registry.sessions(workspaceID: nil).map { record in
            var entry: [String: Any] = [
                "session_id": record.sessionID,
                "agent": record.agentKind.sourceName,
                "state": String(describing: record.state),
                "last_activity": record.lastActivityAt.timeIntervalSince1970,
                "tailer_active": tailers[record.sessionID] != nil,
                "resolution_failed": failedResolutions.contains(record.sessionID),
            ]
            entry["workspace_id"] = record.workspaceID
            entry["surface_id"] = record.surfaceID
            entry["transcript_path"] = record.transcriptPath
            if let pid = record.pid {
                entry["pid"] = pid
                entry["pid_alive"] = kill(pid_t(pid), 0) == 0
            }
            return entry
        }
    }

    // MARK: - Internals

    @discardableResult
    private func ensureTailer(
        for record: AgentChatSessionRecord,
        resolvePath: () -> String?
    ) -> AgentChatTranscriptTailer? {
        guard !didShutdown else { return nil }
        if let existing = tailers[record.sessionID] {
            return existing
        }
        guard !failedResolutions.contains(record.sessionID) else { return nil }
        guard let path = resolvePath() else {
            failedResolutions.insert(record.sessionID)
            #if DEBUG
            cmuxDebugLog(
                "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
                + "kind=\(record.agentKind.sourceName) cwd=\(record.workingDirectory ?? "nil") UNRESOLVED"
            )
            #endif
            return nil
        }
        failedResolutions.remove(record.sessionID)
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
            + "file=\((path as NSString).lastPathComponent)"
        )
        #endif
        let sessionID = record.sessionID
        let agentKind = record.agentKind
        let tailer = AgentChatTranscriptTailer(
            sessionID: sessionID,
            agentKind: agentKind,
            path: path
        ) { [weak self] batch in
            await self?.publishBatch(batch, sessionID: sessionID)
        }
        tailers[sessionID] = tailer
        if record.transcriptPath != path {
            registry.update(sessionID: record.sessionID) { $0.transcriptPath = path }
        }
        Task { await tailer.start() }
        return tailer
    }

    private func publishBatch(_ batch: AgentChatTranscriptTailer.Batch, sessionID: String) {
        guard !didShutdown else { return }
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.batch session=\(sessionID.prefix(8)) "
            + "appended=\(batch.appended.count) updated=\(batch.updated.count) "
            + "reset=\(batch.didReset ? 1 : 0) title=\(batch.discoveredTitle != nil ? 1 : 0)"
        )
        #endif
        if let title = batch.discoveredTitle {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        if let completedAt = Self.completedAssistantTurnTimestamp(in: batch.appended) {
            registry.noteAssistantTurnCompleted(sessionID: sessionID, at: completedAt)
        }
    }


    private static func completedAssistantTurnTimestamp(in messages: [ChatMessage]) -> Date? {
        guard !messages.isEmpty else { return nil }
        var completedAt: Date?
        for message in messages where message.role == .agent {
            switch message.kind {
            case .prose, .thought, .unsupported:
                completedAt = max(completedAt ?? message.timestamp, message.timestamp)
            case .toolUse, .terminal, .fileEdit, .permissionRequest, .question:
                return nil
            case .status:
                break
            case .attachment:
                break
            }
        }
        return completedAt
    }

    private func handleRecordChange(_ record: AgentChatSessionRecord, previous: AgentChatSessionRecord?) {
        if record.state == .ended {
            _ = record.agentKind == .codex
                || endedListability.update(record, previous: previous, resolver: resolver, now: now())
        } else {
            endedListability.remove(sessionID: record.sessionID)
        }
        let stateChanged = previous?.state != record.state
        let transcriptBecameAvailable = previous?.transcriptPath == nil && record.transcriptPath != nil
        let liveProjectionChanged = Self.sidebarProjectionChangedMeaningfully(previous: previous, current: record)
        let historyChanged = record.state == .ended && (stateChanged || transcriptBecameAvailable)
        publishSidebarChange(liveChanged: liveProjectionChanged, historyChanged: historyChanged)
        if transcriptBecameAvailable {
            fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
            failedResolutions.remove(record.sessionID)
        }
        if stateChanged, record.state == .ended {
            fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
            if let tailer = tailers.removeValue(forKey: record.sessionID) {
                // The transcript can no longer grow; release the file watcher
                // and cache instead of holding them until app quit. Evicting
                // only on the TRANSITION keeps unrelated record updates (title
                // discovery while paging an ended session) from churning it.
                Task { await tailer.stop() }
            }
        }
    }

    private func handleRecordRemoval(_ record: AgentChatSessionRecord) {
        publishSidebarChange(liveChanged: true, historyChanged: false)
        fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
        if let tailer = tailers.removeValue(forKey: record.sessionID) {
            Task { await tailer.stop() }
        }
        failedResolutions.remove(record.sessionID)
        endedListability.remove(sessionID: record.sessionID)
    }


}
