import CmuxCore
import Foundation
import Testing
import CmuxSidebar
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceProgramStatusTests {
    @Test func projectsMostUrgentPanelRecord() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, id: "deploy", message: "Approve?"),
            panelId: panelId
        )
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "bell.fill")
        #expect(entry.value.contains("Approve?"))
        #expect(workspace.programStatusStoresByPanelId[panelId]?.mostUrgentRecord()?.state == .blocked)
    }

    @Test func programStatusIsNotAgentLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .auth, app: "brew"),
            panelId: panelId
        )
        #expect(workspace.agentLifecycleStatesByPanelId[panelId] == nil)
        #expect(workspace.agentRuntimeState(forPanelId: panelId) == nil)
    }

    @Test func nativeOMPStatusesDriveBadgesWithoutHookPIDs() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        let firstTabId = try #require(workspace.surfaceIdFromPanelId(firstPanelId))
        let secondTabId = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))
        workspace.applyProgramStatus(ProgramStatusReport(state: .working, app: "omp"), panelId: firstPanelId)
        workspace.applyProgramStatus(ProgramStatusReport(state: .done, app: "omp"), panelId: secondPanel.id)

        let workingEntry = try #require(workspace.agentStatusEntry(key: Workspace.programStatusKey, panelId: firstPanelId))
        #expect(AgentStatusPresentation(entry: workingEntry)?.state == .running)
        #expect(workspace.bonsplitController.tab(firstTabId)?.statusBadge?.isAnimating == true)
        #expect(workspace.bonsplitController.tab(secondTabId)?.statusBadge?.isAnimating == false)
        #expect(workspace.agentPIDs.isEmpty)
        #expect(workspace.agentLifecycleStatesByPanelId.isEmpty)

        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: firstPanelId)
        #expect(workspace.bonsplitController.tab(firstTabId)?.statusBadge == nil)
        #expect(workspace.bonsplitController.tab(secondTabId)?.statusBadge?.isAnimating == false)
        workspace.resetSidebarContext(reason: "native_status_badge_test")
        #expect(workspace.bonsplitController.tab(secondTabId)?.statusBadge == nil)
    }

    @Test func completionAcknowledgementSurvivesLateReportsUntilANewActiveTurn() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let otherPanel = try #require(workspace.newTerminalSplit(from: panelId, orientation: .horizontal, focus: false))
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let otherTabId = try #require(workspace.surfaceIdFromPanelId(otherPanel.id))
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64_011, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil
        )
        workspace.setAgentLifecycle(key: "omp", panelId: panelId, lifecycle: .idle)
        workspace.setStatusEntry(SidebarStatusEntry(key: "omp", value: "hook ended", icon: "pause.circle.fill"), key: "omp", panelId: panelId)
        workspace.setAgentLifecycle(key: "omp", panelId: otherPanel.id, lifecycle: .running)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "other pane working", icon: "bolt.fill", workState: .running
        ), key: "omp", panelId: otherPanel.id)
        workspace.applyProgramStatus(ProgramStatusReport(state: .done, app: "omp"), panelId: panelId)

        let completed = try #require(workspace.terminalAgentStatusEntryVisibleForDisplay(panelId: panelId))
        #expect(completed.key == Workspace.programStatusKey)
        #expect(AgentStatusPresentation(entry: completed)?.state == .completed)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.symbolName == "checkmark.circle.fill")
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().count == 2)

        workspace.dismissCompletedAgentStatus(panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        #expect(workspace.bonsplitController.tab(otherTabId)?.statusBadge?.isAnimating == true)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.value) == ["other pane working"])
        #expect(workspace.programStatusStoresByPanelId[panelId]?.record(id: "")?.state == .done)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["omp"] == .idle)

        workspace.setStatusEntry(SidebarStatusEntry(key: "omp", value: "late hook end", icon: "pause.circle.fill"), key: "omp", panelId: panelId)
        workspace.applyProgramStatus(ProgramStatusReport(state: .idle, app: "omp"), panelId: panelId)
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.value) == ["other pane working"])

        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        #expect(!workspace.agentLifecycleStatesVisibleForDisplay().contains(.idle))
        workspace.setAgentLifecycle(key: "omp", panelId: panelId, lifecycle: .running)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "new hook turn", icon: "bolt.fill", workState: .running
        ), key: "omp", panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.isAnimating == true)
        workspace.setAgentLifecycle(key: "omp", panelId: panelId, lifecycle: .idle)
        workspace.setStatusEntry(SidebarStatusEntry(key: "omp", value: "new hook end", icon: "pause.circle.fill"), key: "omp", panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.symbolName == "checkmark.circle.fill")
        workspace.dismissCompletedAgentStatus()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        #expect(workspace.bonsplitController.tab(otherTabId)?.statusBadge?.isAnimating == true)

        workspace.applyProgramStatus(ProgramStatusReport(state: .working, app: "omp"), panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.isAnimating == true)
        workspace.applyProgramStatus(ProgramStatusReport(state: .done, app: "omp"), panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.symbolName == "checkmark.circle.fill")
        workspace.dismissCompletedAgentStatus()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        workspace.applyProgramStatus(ProgramStatusReport(state: .working, id: "build", app: "cargo"), panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.isAnimating == true)
        workspace.applyProgramStatus(ProgramStatusReport(state: .done, id: "build", app: "cargo", message: "Build complete"), panelId: panelId)
        #expect(workspace.terminalAgentStatusEntryVisibleForDisplay(panelId: panelId)?.value == "cargo · Build complete")
        workspace.applyProgramStatus(ProgramStatusReport(state: .clear, id: "build"), panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        workspace.applyProgramStatus(ProgramStatusReport(state: .error, app: "omp"), panelId: panelId)
        workspace.dismissCompletedAgentStatus()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.symbolName == "exclamationmark.triangle.fill")
    }

    @Test func badgePreferencesUpdateExistingReportsWithoutHidingActiveOrErrorStates() throws {
        let suiteName = "WorkspaceProgramStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(settings: UserDefaultsSettingsClient(defaults: defaults))
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        defaults.set(false, forKey: "sidebarShowInactiveAgentStatus")

        for state in [ProgramStatusState.idle, .done, .working, .blocked, .error] {
            workspace.applyProgramStatus(ProgramStatusReport(state: state, app: "omp"), panelId: panelId)
            let hidden = state == .idle || state == .done
            #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty == hidden)
            #expect((workspace.bonsplitController.tab(tabId)?.statusBadge == nil) == hidden)
        }

        workspace.applyProgramStatus(ProgramStatusReport(state: .done, app: "omp"), panelId: panelId)
        defaults.set(true, forKey: "sidebarShowInactiveAgentStatus")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().count == 1)
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.symbolName == "checkmark.circle.fill")

        workspace.applyProgramStatus(ProgramStatusReport(state: .working, app: "omp"), panelId: panelId)
        defaults.set(false, forKey: "sidebarAnimateAgentStatus")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.isAnimating == false)
        defaults.set(true, forKey: "sidebarAnimateAgentStatus")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge?.isAnimating == true)

        defaults.set(false, forKey: "sidebarShowAgentStatusInTabs")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge == nil)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().count == 1)
        defaults.set(true, forKey: "sidebarShowAgentStatusInTabs")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.bonsplitController.tab(tabId)?.statusBadge != nil)
    }

    @Test func nativeReportsShadowALaterHookUntilClearedEvenWhenInactiveIsHidden() throws {
        let suiteName = "WorkspaceProgramStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(settings: UserDefaultsSettingsClient(defaults: defaults))
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        reporter.arguments = ["30"]
        try reporter.run()
        defer {
            _ = workspace.clearAgentPID(key: "omp", panelId: panelId, clearStatus: true, refreshPorts: false)
            if reporter.isRunning { reporter.terminate() }
            reporter.waitUntilExit()
        }
        workspace.recordAgentPID(key: "omp", pid: reporter.processIdentifier, panelId: panelId, refreshPorts: false)
        workspace.applyProgramStatus(ProgramStatusReport(state: .idle, app: "omp"), panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId) == nil)
        #expect(workspace.programStatusStoresByPanelId[panelId]?.record(id: "")?.state == .idle)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "stale hook", icon: "bolt.fill", workState: .running
        ), key: "omp", panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId) == nil)

        workspace.applyProgramStatus(ProgramStatusReport(state: .blocked, kind: .question, app: "omp"), panelId: panelId)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "late hook", icon: "bolt.fill", timestamp: .distantFuture, workState: .running
        ), key: "omp", panelId: panelId)

        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.key) == [Workspace.programStatusKey])
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId)?.symbolName == "bell.fill")
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId)?.isAnimating == false)

        workspace.applyProgramStatus(ProgramStatusReport(state: .idle, app: "omp"), panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId) == nil)
        workspace.applyProgramStatus(ProgramStatusReport(state: .done, app: "omp"), panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.key) == [Workspace.programStatusKey])
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId)?.symbolName == "checkmark.circle.fill")
        defaults.set(false, forKey: "sidebarShowInactiveAgentStatus")
        workspace.refreshTerminalTabAgentStatusBadges()
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId) == nil)

        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.key) == ["omp"])
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId)?.isAnimating == true)

        workspace.setStatusEntry(SidebarStatusEntry(key: "omp", value: "hook idle", icon: "pause.circle.fill"), key: "omp", panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId) == nil)
        defaults.set(true, forKey: "sidebarShowInactiveAgentStatus")
        workspace.refreshTerminalTabAgentStatusBadges()
        let hookIdle = try #require(workspace.sidebarStatusEntriesVisibleForDisplay().first)
        #expect(AgentStatusPresentation(entry: hookIdle)?.state == .completed)
        #expect(workspace.terminalTabAgentStatusBadge(forPanelId: panelId)?.symbolName == "checkmark.circle.fill")

        workspace.applyProgramStatus(ProgramStatusReport(state: .blocked, kind: .permission, app: "cargo"), panelId: panelId)
        #expect(Set(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.key)) == ["omp", Workspace.programStatusKey])
    }

    @Test func anotherPanesNewerHookDoesNotReplaceThisPanesWinningAgent() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false))
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64_011, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil
        )
        workspace.setAgentLifecycle(key: "omp", panelId: firstPanelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "omp", panelId: secondPanel.id, lifecycle: .running)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "old pane report", icon: "pause.circle.fill", timestamp: Date(timeIntervalSince1970: 1_000)
        ), key: "omp", panelId: firstPanelId)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "codex", value: "current first pane", icon: "bolt.fill", timestamp: Date(timeIntervalSince1970: 2_000)
        ), key: "codex", panelId: firstPanelId)
        workspace.setStatusEntry(SidebarStatusEntry(
            key: "omp", value: "current second pane", icon: "bolt.fill", timestamp: Date(timeIntervalSince1970: 3_000)
        ), key: "omp", panelId: secondPanel.id)

        let entries = workspace.sidebarStatusEntriesVisibleForDisplay()
        #expect(Set(entries.map(\.key)) == ["codex", "omp"])
        #expect(entries.first { $0.key == "codex" }?.value == "current first pane")
        #expect(workspace.terminalAgentStatusEntryVisibleForDisplay(panelId: firstPanelId)?.key == "codex")
        #expect(workspace.terminalAgentStatusEntryVisibleForDisplay(panelId: secondPanel.id)?.key == "omp")
    }

    @Test func workingShowsPercentAndPromptDropsTransientRecords() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo", message: "Lint clean"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, progress: 40, app: "cargo", message: "Building"),
            panelId: panelId
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "cargo · Building · 40%")

        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panelId)
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "checkmark.circle.fill")
        #expect(entry.value == "cargo · Lint clean")

        workspace.dismissCompletedAgentStatus(panelId: panelId)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        #expect(workspace.programStatusStoresByPanelId[panelId]?.record(id: "lint")?.state == .done)
    }

    @Test(arguments: [ProgramStatusState.blocked, .idle])
    func closingPaneRemovesItsProgramStatusRow(state: ProgramStatusState) throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let blockedPanel = try #require(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: state, kind: .permission, app: "terraform"),
            panelId: blockedPanel.id
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey] != nil)

        workspace.discardClosedPanelLifecycleState(
            panelId: blockedPanel.id,
            paneId: nil,
            panel: blockedPanel,
            origin: "program_status_test",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false
        )

        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
        #expect(workspace.programStatusStoresByPanelId[blockedPanel.id] == nil)
    }

    @Test func promptStartOrClearWithoutRecordsDoesNotCreateState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panelId)
        #expect(workspace.programStatusStoresByPanelId[panelId] == nil)
        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: panelId)
        #expect(workspace.programStatusStoresByPanelId[panelId] == nil)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    @Test func programStatusChangesReachTheMacEventStream() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(event: .promptStart, state: .idle),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 3)
        let promptPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(promptPayload["event"] as? String == "prompt_start")
        let records = try #require(promptPayload["records"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["lint"])
    }

    @Test func programStatusClearReachesTheMacEventStream() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .clear, id: "build"),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let clearPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(clearPayload["event"] as? String == "clear")
        #expect(clearPayload["id"] as? String == "build")
        #expect(clearPayload["record"] is NSNull)
        let records = try #require(clearPayload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func transientCleanupPublishesOnceBeforePromptStartNoOp() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, id: "deploy"),
            panelId: panelId
        )
        workspace.dropTransientProgramStatus(panelId: panelId)
        // Shell integration can deliver this after prompt-idle cleanup. It is
        // intentionally a no-op because the snapshot was already published.
        workspace.applyProgramStatus(
            ProgramStatusReport(event: .promptStart, state: .idle),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let cleanupPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(cleanupPayload["event"] as? String == "transient_drop")
        let records = try #require(cleanupPayload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func acknowledgingCompletionPreservesProtocolSnapshotAndEventStream() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "build"),
            panelId: panelId
        )
        workspace.dismissCompletedAgentStatus(panelId: panelId)
        workspace.dismissCompletedAgentStatus(panelId: panelId)
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 1)
        let payload = try #require(events.first?["payload"] as? [String: Any])
        let records = try #require(payload["records"] as? [[String: Any]])
        #expect(records.first?["state"] as? String == "done")
        #expect(workspace.programStatusStoresByPanelId[panelId]?.record(id: "build")?.state == .done)
    }

    @Test(arguments: [ProgramStatusState.blocked, .idle])
    func movedPaneKeepsItsProgramStatusAndCompletionAcknowledgement(state: ProgramStatusState) throws {
        let source = Workspace()
        let destination = Workspace()
        let firstPanelId = try #require(source.focusedPanelId)
        let movedPanel = try #require(
            source.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        source.applyProgramStatus(
            ProgramStatusReport(state: state, kind: .question, app: "deploy", message: "Region?"),
            panelId: movedPanel.id
        )
        if state == .idle { source.dismissCompletedAgentStatus(panelId: movedPanel.id) }

        let detached = try #require(source.detachSurface(panelId: movedPanel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))

        #expect(source.statusEntries[Workspace.programStatusKey] == nil)
        #expect(destination.programStatusStoresByPanelId[movedPanel.id]?.mostUrgentRecord(includingIdle: true)?.state == state)
        if state == .idle {
            #expect(destination.terminalTabAgentStatusBadge(forPanelId: movedPanel.id) == nil)
            #expect(destination.sidebarStatusEntriesVisibleForDisplay().isEmpty)
        } else {
            #expect(destination.statusEntries[Workspace.programStatusKey]?.value == "deploy · Region?")
        }
    }

    @Test func closingTerminalsPublishesRemovedSnapshotOnlyForReportingPanes() throws {
        let workspace = Workspace()
        let reportingPanelId = try #require(workspace.focusedPanelId)
        let quietPanel = try #require(
            workspace.newTerminalSplit(from: reportingPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo"),
            panelId: reportingPanelId
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.teardownAllPanels()
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 1)
        let removed = try #require(events.first)
        #expect(removed["workspace_id"] as? String == workspace.id.uuidString)
        #expect(removed["surface_id"] as? String == reportingPanelId.uuidString)
        #expect(removed["surface_id"] as? String != quietPanel.id.uuidString)
        let payload = try #require(removed["payload"] as? [String: Any])
        #expect(payload["event"] as? String == "removed")
        #expect(payload["record"] is NSNull)
        #expect(payload["records_total"] as? Int == 0)
        let records = try #require(payload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func movedPanePublishesRemovalAndAdoptionUnderEachWorkspace() throws {
        let source = Workspace()
        let destination = Workspace()
        let firstPanelId = try #require(source.focusedPanelId)
        let movedPanel = try #require(
            source.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        source.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .question, id: "deploy", app: "deploy"),
            panelId: movedPanel.id
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let detached = try #require(source.detachSurface(panelId: movedPanel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let removed = try #require(events.first)
        #expect(removed["workspace_id"] as? String == source.id.uuidString)
        #expect(removed["surface_id"] as? String == movedPanel.id.uuidString)
        let removedPayload = try #require(removed["payload"] as? [String: Any])
        #expect(removedPayload["event"] as? String == "removed")
        #expect((removedPayload["records"] as? [[String: Any]])?.isEmpty == true)

        let adopted = try #require(events.last)
        #expect(adopted["workspace_id"] as? String == destination.id.uuidString)
        #expect(adopted["surface_id"] as? String == movedPanel.id.uuidString)
        let adoptedPayload = try #require(adopted["payload"] as? [String: Any])
        #expect(adoptedPayload["event"] as? String == "adopted")
        #expect(adoptedPayload["record"] is NSNull)
        let records = try #require(adoptedPayload["records"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["deploy"])
        #expect(records.first?["state"] as? String == "blocked")
        #expect(records.first?["kind"] as? String == "question")
    }

    @Test func sidebarResetPublishesClearForReportingPanes() throws {
        let workspace = Workspace()
        let reportingPanelId = try #require(workspace.focusedPanelId)
        _ = try #require(
            workspace.newTerminalSplit(from: reportingPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: reportingPanelId
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.resetSidebarContext(reason: "test")
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 1)
        let cleared = try #require(events.first)
        #expect(cleared["workspace_id"] as? String == workspace.id.uuidString)
        #expect(cleared["surface_id"] as? String == reportingPanelId.uuidString)
        let payload = try #require(cleared["payload"] as? [String: Any])
        #expect(payload["event"] as? String == "clear")
        #expect(payload["id"] is NSNull)
        let records = try #require(payload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
        #expect(workspace.programStatusStoresByPanelId.isEmpty)
    }

    @Test func sanitizesInvisibleFormattingAndCapsDisplay() {
        let workspace = Workspace()
        let value = workspace.sanitizedProgramStatusText("hello\u{202E}world")
        #expect(value == "helloworld")
        #expect(workspace.sanitizedProgramStatusText(String(repeating: "x", count: 600))?.count == 512)
    }
}
