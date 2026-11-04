import CmuxSidebar
import Foundation

extension Workspace {
    /// The workspace row is an aggregate of every pane: each visible key shows
    /// its most urgent pane's entry (see `mostUrgentPanelStatusEntry`), not
    /// whichever pane wrote last or the focused one.
    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        let displaySettings = agentStatusDisplaySettings
        return statusEntries.values.compactMap { entry in
            guard shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys) else {
                return nil
            }
            let projected: SidebarStatusEntry
            if entry.key == Self.programStatusKey {
                guard let native = mostUrgentPanelStatusEntry(forKey: entry.key, forDisplay: true) else { return nil }
                projected = native
            } else {
                projected = mostUrgentPanelStatusEntry(forKey: entry.key, forDisplay: true) ?? entry
            }
            if let presentation = AgentStatusPresentation(entry: projected), !displaySettings.allows(presentation) {
                return nil
            }
            return projected
        }
    }

    /// Keys with at least one live pane waiting on the person; the row sorts
    /// them ahead of other entries of the same priority.
    func sidebarStatusKeysNeedingInput() -> Set<String> {
        var keys = Set<String>()
        for (panelId, lifecycleStates) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for (key, lifecycle) in lifecycleStates where lifecycle == .needsInput {
                keys.insert(key)
            }
        }
        return keys
    }

    /// A pane's own last-reported entry for `key`, while the workspace still
    /// shows that key at all.
    func agentStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        guard statusEntries[key] != nil else { return nil }
        return agentStatusEntriesByPanelId[panelId]?[key]
    }

    /// The newest visible report owned by this terminal, never a workspace
    /// summary or a different pane's report for the same agent key.
    func terminalAgentStatusEntryVisibleForDisplay(panelId: UUID) -> SidebarStatusEntry? {
        guard panels[panelId] is TerminalPanel,
              let entries = agentStatusEntriesByPanelId[panelId] else { return nil }
        var newest: SidebarStatusEntry?
        for entry in entries.values {
            guard statusEntries[entry.key] != nil else { continue }
            guard !isCompletedAgentStatusDismissed(entry, panelId: panelId) else { continue }
            if entry.key == Self.programStatusKey {
                // OSC reports belong to their terminal store, not a hook PID.
                guard programStatusStoresByPanelId[panelId]?.mostUrgentRecord(includingIdle: true) != nil else { continue }
            } else {
                guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else { continue }
                guard !isHookStatusShadowedByNativeAgent(key: entry.key, panelId: panelId) else { continue }
                let ownsLocalPID = agentPIDKeysByPanelId[panelId]?.contains {
                    agentStatusKey(forAgentPIDKey: $0) == entry.key
                } ?? false
                guard ownsLocalPID || (showsRelayHostAgentStatus
                    && agentLifecycleStatesByPanelId[panelId]?[entry.key] != nil) else { continue }
            }
            if let current = newest, !isSidebarStatusEntryLessCurrent(current, than: entry) {
                continue
            }
            newest = entry
        }
        return newest
    }

    /// Acknowledges completed chrome without changing activity or hibernation evidence.
    /// Native and hook reports share identities, so a late report cannot revive it.
    func dismissCompletedAgentStatus(panelId: UUID? = nil) {
        let panelIds = panelId.map { [$0] } ?? Array(panels.keys)
        for panelId in panelIds where panels[panelId] != nil {
            var identities = dismissedAgentCompletionIdentitiesByPanelId[panelId, default: []]
            let previous = identities
            for entry in agentStatusEntriesByPanelId[panelId, default: [:]].values
            where entry.key != Self.programStatusKey && AgentStatusPresentation(entry: entry)?.state == .completed {
                identities.insert(agentCompletionIdentity(for: entry.key))
            }
            if let store = programStatusStoresByPanelId[panelId] {
                for record in store.records where record.state == .idle || record.state == .done {
                    identities.insert(programStatusCompletionIdentity(for: record, store: store))
                }
            }
            guard identities != previous else { continue }
            dismissedAgentCompletionIdentitiesByPanelId[panelId] = identities
            projectProgramStatus(panelId: panelId)
            syncTerminalTabAgentStatusBadge(forPanelId: panelId)
        }
    }

    func agentCompletionIdentity(for identity: String) -> String {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "agent:\(TerminalTabAgentIconResolver().agentID(forIdentity: normalized) ?? normalized)"
    }

    func programStatusCompletionIdentity(for record: ProgramStatusRecord, store: ProgramStatusRecordStore) -> String {
        if let app = store.effectiveApp(for: record) {
            return agentCompletionIdentity(for: app)
        }
        return "program:\(record.id)"
    }

    func isCompletedAgentStatusDismissed(_ entry: SidebarStatusEntry, panelId: UUID) -> Bool {
        // Native projection already excludes acknowledged records from its store.
        guard entry.key != Self.programStatusKey,
              AgentStatusPresentation(entry: entry)?.state == .completed,
              let identities = dismissedAgentCompletionIdentitiesByPanelId[panelId] else { return false }
        return identities.contains(agentCompletionIdentity(for: entry.key))
    }

    func setStatusEntry(_ entry: SidebarStatusEntry, key: String, panelId: UUID?) {
        statusEntries[key] = entry
        if let panelId, panels[panelId] != nil {
            if key != Self.programStatusKey,
               !isHookStatusShadowedByNativeAgent(key: key, panelId: panelId),
               let state = AgentStatusPresentation(entry: entry)?.state,
               state == .running || state == .waiting || state == .needsInput {
                dismissedAgentCompletionIdentitiesByPanelId[panelId]?.remove(agentCompletionIdentity(for: key))
                if state == .running {
                    AppDelegate.shared?.notificationStore?.consumeCompletedAgentNotifications(
                        forTabId: id,
                        surfaceId: panelId,
                        agentKind: key
                    )
                }
            }
            agentStatusEntriesByPanelId[panelId, default: [:]][key] = entry
            syncTerminalTabAgentStatusBadge(forPanelId: panelId)
        }
    }

    func clearStatusEntry(key: String, panelId: UUID?) {
        guard let panelId,
              AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key) else {
            removeStatusEntry(forKey: key)
            return
        }
        removePanelStatusEntry(key: key, panelId: panelId)
        if let remainingEntry = mostUrgentPanelStatusEntry(forKey: key) {
            statusEntries[key] = remainingEntry
        } else {
            removeStatusEntry(forKey: key)
        }
    }

    /// Removes the key and every pane's copy of it, so a later report for the
    /// key never revives an older pane's text.
    @discardableResult
    func removeStatusEntry(forKey key: String) -> Bool {
        for panelId in Array(agentStatusEntriesByPanelId.keys) {
            removePanelStatusEntry(key: key, panelId: panelId)
        }
        return statusEntries.removeValue(forKey: key) != nil
    }

    /// Drops one pane's copy, e.g. when its agent lifecycle for the key ends;
    /// the row then falls back to the workspace entry for that pane.
    func removePanelStatusEntry(key: String, panelId: UUID) {
        agentStatusEntriesByPanelId[panelId]?.removeValue(forKey: key)
        if agentStatusEntriesByPanelId[panelId]?.isEmpty == true {
            agentStatusEntriesByPanelId.removeValue(forKey: panelId)
        }
        syncTerminalTabAgentStatusBadge(forPanelId: panelId)
    }

    /// Several panes can report the same agent key (two Claude panes share
    /// `claude_code`). The pane that most needs the person wins: needs input,
    /// then running, then unknown, then idle; the newest report breaks ties.
    /// Only live panes that still own the agent (a lifecycle state or an agent
    /// PID for the key) count, so an ended pane's last report never lingers.
    /// Nil when no pane-scoped report exists; callers fall back to the
    /// workspace entry.
    func mostUrgentPanelStatusEntry(forKey key: String, forDisplay: Bool = false) -> SidebarStatusEntry? {
        var winner: (rank: Int, entry: SidebarStatusEntry)?
        for (panelId, entries) in agentStatusEntriesByPanelId where panels[panelId] != nil {
            guard let entry = entries[key] else { continue }
            if forDisplay && isCompletedAgentStatusDismissed(entry, panelId: panelId) { continue }
            if key == Self.programStatusKey {
                guard programStatusStoresByPanelId[panelId]?.mostUrgentRecord(includingIdle: true) != nil else { continue }
            } else {
                guard panelOwnsAgentStatus(key: key, panelId: panelId) else { continue }
            }
            guard !isHookStatusShadowedByNativeAgent(key: key, panelId: panelId) else { continue }
            let rank = key == Self.programStatusKey
                ? programStatusUrgencyByPanelId[panelId, default: 0]
                : Self.sidebarStatusUrgencyRank(agentLifecycleStatesByPanelId[panelId]?[key])
            if let current = winner, (current.rank, current.entry.timestamp) >= (rank, entry.timestamp) {
                continue
            }
            winner = (rank, entry)
        }
        return winner?.entry
    }

    /// Compact chrome must not revive lifecycle reports shadowed by native status.
    func agentLifecycleStatesVisibleForDisplay() -> [AgentHibernationLifecycleState] {
        var result: [AgentHibernationLifecycleState] = []
        for (panelId, states) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for (key, state) in states where !AgentHibernationLifecycleStatusKeys.isManualKey(key)
                && !isHookStatusShadowedByNativeAgent(key: key, panelId: panelId) {
                if state == .idle,
                   dismissedAgentCompletionIdentitiesByPanelId[panelId]?.contains(agentCompletionIdentity(for: key)) == true {
                    continue
                }
                result.append(state)
            }
        }
        return result
    }

    /// One terminal's native agent state owns its display until that report is removed.
    private func isHookStatusShadowedByNativeAgent(key: String, panelId: UUID) -> Bool {
        guard key != Self.programStatusKey,
              let store = programStatusStoresByPanelId[panelId],
              let record = store.mostUrgentRecord(includingIdle: true),
              let app = store.effectiveApp(for: record) else { return false }
        let resolver = TerminalTabAgentIconResolver()
        guard let nativeAgentID = resolver.agentID(forIdentity: app) else { return false }
        return nativeAgentID == resolver.agentID(forIdentity: key)
    }

    private func panelOwnsAgentStatus(key: String, panelId: UUID) -> Bool {
        if agentLifecycleStatesByPanelId[panelId]?[key] != nil { return true }
        return agentPIDKeysByPanelId[panelId]?.contains { agentStatusKey(forAgentPIDKey: $0) == key } ?? false
    }

    static func sidebarStatusUrgencyRank(_ lifecycle: AgentHibernationLifecycleState?) -> Int {
        switch lifecycle {
        case .running: 4
        case .backgroundWorkPending: 3
        case .needsInput: 2
        case .unknown, nil: 1
        case .idle: 0
        }
    }

    func sidebarStatusUrgencyRank(forKey key: String) -> Int {
        agentLifecycleStatesByPanelId.values
            .compactMap { Self.sidebarStatusUrgencyRank($0[key]) }
            .max() ?? 0
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    /// Structured agent status keys that may show: the newest per live panel
    /// among the agents that panel owns. Local agents own a panel through a
    /// registered PID; relay-host agents have no local PID, so on relay-backed
    /// workspaces the hook-reported lifecycle on a live panel is the ownership
    /// evidence instead.
    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        if showsRelayHostAgentStatus {
            for (panelId, lifecycleStates) in agentLifecycleStatesByPanelId
            where panels[panelId] != nil {
                for statusKey in lifecycleStates.keys
                where AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
                    && statusEntries[statusKey] != nil {
                    statusKeysByPanelId[panelId, default: []].insert(statusKey)
                }
            }
        }
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        var visibleStatusKeys = Set<String>()
        for (panelId, statusKeys) in statusKeysByPanelId {
            let winningEntry = statusKeys.compactMap { key -> SidebarStatusEntry? in
                guard !isHookStatusShadowedByNativeAgent(key: key, panelId: panelId) else { return nil }
                guard let entry = agentStatusEntriesByPanelId[panelId]?[key] ?? statusEntries[key],
                      !isCompletedAgentStatusDismissed(entry, panelId: panelId) else { return nil }
                return entry
            }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    /// Relay-host agents report state only through relayed hooks. cmux-tui SSH
    /// workspaces publish their own remote status keys instead.
    var showsRelayHostAgentStatus: Bool {
        (remoteConfiguration?.relayPort ?? 0) > 0 && !usesSSHTui
    }

    /// Drops relay-host agent status and lifecycle once the relay is down: no
    /// local PID can prove the remote agent survived, and a hook that would
    /// clear it can no longer arrive. The next relayed hook reports afresh.
    /// Keys a local agent PID still owns are left alone.
    func clearRelayHostAgentStatus() {
        guard showsRelayHostAgentStatus else { return }
        let localAgentKeys = Set(agentPIDs.keys)
        for statusKey in AgentHibernationLifecycleStatusKeys.allowedStatusKeys
            where !localAgentKeys.contains(statusKey) {
            removeStatusEntry(forKey: statusKey)
            _ = clearAgentLifecycle(key: statusKey)
        }
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
    }
}

extension Workspace {
    /// Returns the existing sidebar agent identity when this panel is in an
    /// active turn. Close warnings use the same sidebar lifecycle evidence
    /// rather than introducing another process detector.
    func activeAgentCloseWarningInfo(panelId: UUID) -> String? {
        guard panels[panelId] != nil else { return nil }
        let states = agentLifecycleStatesByPanelId[panelId, default: [:]]
        if let key = states.first(where: { $0.value == .running })?.key {
            return Self.closeWarningAgentDisplayName(for: key)
        }
        let entries = agentStatusEntriesByPanelId[panelId, default: [:]]
        if let key = entries.first(where: { entry in
            entry.value.workState == .running || entry.value.workState == .subagents
        })?.key {
            return Self.closeWarningAgentDisplayName(for: key)
        }
        return nil
    }

    private static func closeWarningAgentDisplayName(for key: String) -> String {
        key.split(separator: "_", omittingEmptySubsequences: true)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
