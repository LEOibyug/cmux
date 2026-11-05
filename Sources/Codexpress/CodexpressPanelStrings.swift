import Foundation

/// Localized copy shared by the native Codexpress footer and its immutable rows.
struct CodexpressPanelStrings {
    var title: String { String(localized: "codexpress.panel.title", defaultValue: "Codexpress") }
    var expand: String { String(localized: "codexpress.panel.expand", defaultValue: "Expand Codexpress") }
    var collapse: String { String(localized: "codexpress.panel.collapse", defaultValue: "Collapse Codexpress") }
    var open: String { String(localized: "codexpress.panel.open", defaultValue: "Open Codexpress") }
    var running: String { String(localized: "codexpress.status.running", defaultValue: "Running") }
    var stopped: String { String(localized: "codexpress.status.stopped", defaultValue: "Stopped") }
    var connecting: String { String(localized: "codexpress.status.connecting", defaultValue: "Connecting…") }
    var syncing: String { String(localized: "codexpress.status.syncing", defaultValue: "Syncing…") }
    var unknown: String { String(localized: "codexpress.value.unknown", defaultValue: "Unknown") }
    var stale: String { String(localized: "codexpress.value.stale", defaultValue: "Stale") }
    var estimated: String { String(localized: "codexpress.balance.estimated", defaultValue: "Estimated") }
    var spendPending: String { String(localized: "codexpress.balance.spendPending", defaultValue: "Spend pending") }
    var currencyUnknown: String { String(localized: "codexpress.balance.currencyUnknown", defaultValue: "Currency unknown") }
    var balance: String { String(localized: "codexpress.balance.label", defaultValue: "Balance") }
    var official: String { String(localized: "codexpress.source.official", defaultValue: "Official account") }
    var provider: String { String(localized: "codexpress.source.provider", defaultValue: "Provider") }
    var healthy: String { String(localized: "codexpress.source.healthy", defaultValue: "Healthy") }
    var unavailable: String { String(localized: "codexpress.source.unavailable", defaultValue: "Unavailable") }
    var disabled: String { String(localized: "codexpress.source.disabled", defaultValue: "Disabled") }
    var cooldown: String { String(localized: "codexpress.source.cooldown", defaultValue: "Cooling down") }
    var exhausted: String { String(localized: "codexpress.source.exhausted", defaultValue: "Exhausted") }
    var authRequired: String { String(localized: "codexpress.source.authRequired", defaultValue: "Sign-in required in Codexpress") }
    var proxyError: String { String(localized: "codexpress.source.proxyError", defaultValue: "Connection error") }
    var active: String { String(localized: "codexpress.source.active", defaultValue: "Active requests") }
    var weekWindow: String { String(localized: "codexpress.quota.week", defaultValue: "week") }
    var cards: String { String(localized: "codexpress.quota.cards", defaultValue: "Reset cards") }
    var resetTime: String { String(localized: "codexpress.quota.resets", defaultValue: "Resets") }
    var remaining: String { String(localized: "codexpress.quota.remaining", defaultValue: "Remaining") }
    var preempt: String { String(localized: "codexpress.action.preempt", defaultValue: "Preempt") }
    var cancel: String { String(localized: "codexpress.action.cancel", defaultValue: "Stop") }
    var recover: String { String(localized: "codexpress.action.recover", defaultValue: "Recover") }
    var refresh: String { String(localized: "codexpress.action.refresh", defaultValue: "Refresh") }
    var reset: String { String(localized: "codexpress.action.reset", defaultValue: "Reset…") }
    var resetHelp: String { String(localized: "codexpress.action.resetHelp", defaultValue: "Ask Codexpress to confirm a reset card. Nothing is consumed here.") }
    var resetPending: String { String(localized: "codexpress.reset.pending", defaultValue: "Reset awaiting confirmation") }
    var resetVerifying: String { String(localized: "codexpress.reset.verifying", defaultValue: "Reset awaiting verification") }
    var resetCompleted: String { String(localized: "codexpress.reset.completed", defaultValue: "Reset completed") }
    var resetFailed: String { String(localized: "codexpress.reset.failed", defaultValue: "Reset failed") }
    var resetCancelled: String { String(localized: "codexpress.reset.cancelled", defaultValue: "Reset cancelled") }
    var resetUnknown: String { String(localized: "codexpress.reset.unknown", defaultValue: "Reset outcome unknown — check Codexpress") }
    var noSources: String { String(localized: "codexpress.panel.noSources", defaultValue: "No enabled providers") }
    var cached: String { String(localized: "codexpress.panel.cached", defaultValue: "Showing last local status") }
    var automaticMode: String { String(localized: "codexpress.mode.automatic", defaultValue: "Automatic routing") }
    var fixedMode: String { String(localized: "codexpress.mode.fixed", defaultValue: "Fixed routing") }
    var manualMode: String { String(localized: "codexpress.mode.manual", defaultValue: "Manual preemption") }
    var unknownMode: String { String(localized: "codexpress.mode.unknown", defaultValue: "Routing unknown") }
    var dismiss: String { String(localized: "codexpress.action.dismiss", defaultValue: "Dismiss error") }
    var refreshFailed: String { String(localized: "codexpress.refresh.failed", defaultValue: "Balance or quota refresh failed. Last known values are retained.") }

    func nextRefresh(at timestamp: Double) -> String {
        let time = Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
        return String(format: String(localized: "codexpress.refresh.nextQuery", defaultValue: "Next query available: %@"), time)
    }

    func message(for error: CodexpressManagementError) -> String {
        switch error {
        case .notConfigured:
            return String(localized: "codexpress.error.notConfigured", defaultValue: "Enable Management API in Codexpress (updated gateway required).")
        case .missingManualKey:
            return String(localized: "codexpress.error.missingManualKey", defaultValue: "Save a Management API key in Settings > Sidebar to use a manual connection.")
        case .connectionChanged:
            return String(localized: "codexpress.error.connectionChanged", defaultValue: "Connection changed. Loading fresh local status; previous operations will not be sent to this connection.")
        case .disabled:
            return String(localized: "codexpress.error.disabled", defaultValue: "Codexpress local access is disabled.")
        case .insecureConfiguration, .invalidConfiguration:
            return String(localized: "codexpress.error.configuration", defaultValue: "Codexpress local access configuration needs attention.")
        case .unauthorized:
            return String(localized: "codexpress.error.unauthorized", defaultValue: "Codexpress local access was denied.")
        case .unavailable:
            return String(localized: "codexpress.error.unavailable", defaultValue: "Codexpress is unavailable.")
        case .invalidResponse, .httpStatus:
            return String(localized: "codexpress.error.response", defaultValue: "Codexpress could not complete the request.")
        case .refreshFailed(_, _, let nextRetryAt):
            if let nextRetryAt, nextRetryAt.isFinite, nextRetryAt > Date().timeIntervalSince1970 {
                return refreshFailed + "\n" + nextRefresh(at: nextRetryAt)
            }
            return refreshFailed
        case .outcomeUnknown:
            return String(localized: "codexpress.error.outcomeUnknown", defaultValue: "Outcome unknown. Check Codexpress before trying again.")
        }
    }
}
