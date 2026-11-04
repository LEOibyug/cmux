import Foundation

@MainActor
extension TerminalNotificationStore {
    private static let workspaceContextMenuNotificationLimit = 50

    static func isCompletedAgentNotification(
        category: String?,
        kind: String? = nil,
        matchingKind: String? = nil
    ) -> Bool {
        guard category == "turn-complete" || category == "idle-reminder" else { return false }
        guard let matchingKind else { return true }
        guard let kind else { return false }
        let resolver = TerminalTabAgentIconResolver()
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTarget = matchingKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (resolver.agentID(forIdentity: normalizedKind) ?? normalizedKind)
            == (resolver.agentID(forIdentity: normalizedTarget) ?? normalizedTarget)
    }

    func dismissCompletedAgentStatus(forTabId tabId: UUID, surfaceId: UUID? = nil) {
        guard let appDelegate = AppDelegate.shared,
              let workspace = appDelegate.workspaceFor(tabId: tabId)
                ?? appDelegate.tabManager?.tabs.first(where: { $0.id == tabId }) else { return }
        if let surfaceId {
            guard let panelId = workspace.surfaceOwnershipTarget(for: surfaceId)?.containerPanelID else { return }
            workspace.dismissCompletedAgentStatus(panelId: panelId)
        } else {
            workspace.dismissCompletedAgentStatus()
        }
    }

    func dismissAllCompletedAgentStatus() {
        guard let appDelegate = AppDelegate.shared else { return }
        for context in appDelegate.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                workspace.dismissCompletedAgentStatus()
            }
        }
    }

    func notifications(forTabIds tabIds: [UUID]) -> [TerminalNotification] {
        guard !tabIds.isEmpty else { return [] }
        let targetIds = Set(tabIds)
        let sorted = notifications
            .filter { targetIds.contains($0.tabId) }
            .sorted(by: Self.notificationSortPrecedes)
        return Array(sorted.prefix(Self.workspaceContextMenuNotificationLimit))
    }

    /// Visits read ordinary workspace-level alerts, such as cmux's own memory
    /// pressure warning. Completion attention and every pane's indicators stay
    /// intact until their own acknowledgment path runs.
    func markWorkspaceLevelNotificationsRead(forTabId tabId: UUID) {
        // Visits retain completion attention until the user leaves. Exact reads
        // also keep other identities' completion projections untouched.
        markNotificationsReadOnVisit(forTabId: tabId, surfaceId: nil)
    }
}
