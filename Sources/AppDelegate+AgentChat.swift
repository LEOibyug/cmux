import AppKit
import CMUXAgentLaunch
import Foundation

extension AppDelegate {
    /// Workstream feed title mapping extracted because `AppDelegate.swift`
    /// sits at its file-length budget.
    nonisolated static func feedWorkstreamTitle(for event: WorkstreamEvent) -> String? {
        switch event.hookEventName {
        case .preCompact, .postCompact:
            return String(localized: "feed.lifecycle.compaction.title", defaultValue: "Compaction")
        case .subagentStart, .subagentStop:
            return String(localized: "feed.lifecycle.subagent.title", defaultValue: "Subagent")
        default:
            return nil
        }
    }

    @discardableResult
    func executeConfiguredCmuxAction(
        id actionID: String,
        tabManager: TabManager,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        guard let context = mainWindowContext(for: tabManager),
              let action = context.cmuxConfigStore?.resolvedAction(id: actionID) else {
            return false
        }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: preferredWindow
        )
    }

}
