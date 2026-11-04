import Testing
import AppKit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct NotificationUnreadEntryCountTests {


    /// Manual workspace indicators do not create unread notification entries.
    @Test func unreadEntryCountExcludesWorkspaceIndicators() throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let tabId = UUID()
        store.replaceNotificationsForTesting([]) // also clears manual unread state
        let dockCountBefore = store.unreadCount

        store.markUnread(forTabId: tabId) // workspace indicator, no entry
        defer { store.markRead(forTabId: tabId) }

        #expect(store.unreadCount == dockCountBefore + 1)
        #expect(store.unreadNotificationCount == 0)
    }
}
