import Bonsplit
import Foundation

/// Resolves agent identity and provider marks from the shared process/hook definitions.
struct TerminalTabAgentIconResolver {
    func assetName(forStatusKey statusKey: String) -> String? {
        definition(forIdentity: statusKey)?.assetName
    }

    func agentID(forIdentity identity: String) -> String? {
        definition(forIdentity: identity)?.id
    }

    private func definition(forIdentity identity: String) -> CmuxTaskManagerCodingAgentDefinition? {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { definition in
            definition.id == normalized
                || definition.launchKinds.contains(normalized)
                || definition.directBasenames.contains(normalized)
        }
    }
}

extension Workspace {
    /// Returns the current provider mark for one terminal panel, if known.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let resolver = TerminalTabAgentIconResolver()
        let statusKeys = agentPIDKeysByPanelId[panelId, default: []]
            .map(agentStatusKey(forAgentPIDKey:))
            .sorted()
        if let asset = statusKeys.compactMap(resolver.assetName(forStatusKey:)).first {
            return asset
        }
        // A restored snapshot outlives its agent (completed sessions stay for
        // history), so it only names the tab while that agent is running.
        guard let restored = restoredAgentSnapshotsByPanelId[panelId],
              restoredAgentIsRunning(panelId: panelId) else { return nil }
        return restored.registration?.iconAssetName ?? resolver.assetName(forStatusKey: restored.kind.rawValue)
    }

    private func restoredAgentIsRunning(panelId: UUID) -> Bool {
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .autoResumeCommandRunning, .observedAgentCommandRunning:
            return true
        case .manualResumeAvailable, .awaitingAutoResumeCommand, .completedAgentExit, nil:
            return false
        }
    }

    /// Maps only this terminal's authoritative live report into generic tab chrome.
    func terminalTabAgentStatusBadge(forPanelId panelId: UUID) -> TabStatusBadge? {
        guard let entry = terminalAgentStatusEntryVisibleForDisplay(panelId: panelId),
              let presentation = AgentStatusPresentation(entry: entry) else { return nil }
        return TabStatusBadge(
            text: presentation.text,
            symbolName: presentation.symbolName,
            foregroundHex: presentation.foregroundHex,
            backgroundHex: presentation.backgroundHex,
            isAnimating: presentation.isAnimating
        )
    }

    func syncTerminalTabAgentStatusBadge(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel,
              let tabID = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabID) else { return }
        let badge = terminalTabAgentStatusBadge(forPanelId: panelId)
        guard tab.statusBadge != badge else { return }
        bonsplitController.updateTab(tabID, statusBadge: .some(badge))
    }

    /// Reconciles a terminal tab's provider mark after agent lifecycle state changes.
    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        syncTerminalTabAgentStatusBadge(forPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let tabID = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabID) else { return }
        let asset = terminalTabAgentIconAsset(forPanelId: panelId)
        guard tab.iconAsset != asset else { return }
        bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }
}
