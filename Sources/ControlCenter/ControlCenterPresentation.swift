import AppKit

@MainActor
enum ControlCenterPresentation {
    static func show(activate: Bool = false, preferredWindow: NSWindow? = nil) {
        guard let appDelegate = AppDelegate.shared else { return }
        let context: AppDelegate.MainWindowContext? = {
            if let preferred = appDelegate.preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
               appDelegate.resolvedWindow(for: preferred) != nil {
                return preferred
            }
            if let existing = appDelegate.sortedMainWindowContextsForSessionSnapshot().first(where: {
                appDelegate.resolvedWindow(for: $0) != nil
            }) {
                return existing
            }
            let windowId = appDelegate.ensureInitialMainWindowIfNeeded(shouldActivate: false)
            return appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        }()
        guard let context, appDelegate.resolvedWindow(for: context) != nil else { return }

        context.sidebarSelectionState.selection = .controlCenter
        ControlCenterCoordinator.shared.chatPresentationID = UUID()
        if activate {
            _ = appDelegate.focusMainWindow(windowId: context.windowId)
        }
    }
}
