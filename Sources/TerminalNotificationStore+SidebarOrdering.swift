import CmuxSettings
import Foundation

extension TerminalNotificationStore {
    /// Applies admitted notification ordering through the existing local workspace paths.
    /// Agent-activity ordering retains its shared interaction and cooldown throttle.
    func applySidebarOrdering(for notification: TerminalNotification, effects: TerminalNotificationPolicyEffects) {
        guard effects.reorderWorkspace else { return }
        let mode = UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().app.reorderOnNotification)
        switch mode {
        case .off:
            return
        case .notifications:
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        case .agentActivity:
            WorkspaceActivityReorderController.shared.notificationRequestsReorder(
                workspaceId: notification.tabId
            )
        }
    }
}
