import SwiftUI
import CmuxFoundation

/// A read-only source snapshot; mutations are dispatched by the containing card.
struct CodexpressSourceRow: View {
    let source: CodexpressSnapshot.Source
    let settings: CodexpressSettingsSnapshot
    let isTakingOver: Bool
    let isBusy: Bool
    let canAct: Bool
    let isSnapshotStale: Bool
    let resetRequest: CodexpressResetRequest?
    let onTakeOver: () -> Void
    let onCancelTakeover: () -> Void
    let onRecover: () -> Void
    let onRefresh: () -> Void
    let onRequestReset: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let strings = CodexpressPanelStrings()

    var body: some View {
        TimelineView(.explicit(source.refreshRetryAt.map { [Date(timeIntervalSince1970: $0)] } ?? [])) { context in
            row(at: context.date)
        }
    }

    private func row(at date: Date) -> some View {
        let windows = quotaWindows
        let refreshCoolingDown = (source.refreshRetryAt ?? 0) > date.timeIntervalSince1970
        let refreshHelp = refreshHelp(at: date)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 6, height: 6)
                    .symbolEffect(.pulse, options: .repeating, isActive: source.activeRequests > 0 && !reduceMotion)
                    .accessibilityHidden(true)
                Text(displayName)
                    .cmuxFont(size: CGFloat(settings.fontSize + 1), weight: .semibold)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if settings.showRequestCounts {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text(source.activeRequests, format: .number).monospacedDigit()
                    }
                    .cmuxFont(size: CGFloat(settings.fontSize - 2))
                    .foregroundStyle(.secondary)
                    .help(strings.active)
                }
                if isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .cmuxFont(size: CGFloat(settings.fontSize - 2))
                        .foregroundStyle(.orange)
                }
                if settings.showActions {
                    Button(action: isTakingOver ? onCancelTakeover : onTakeOver) {
                        Image(systemName: isTakingOver ? "bolt.circle.fill" : "bolt.fill")
                            .foregroundStyle(isTakingOver ? Color.accentColor : Color.secondary)
                            .frame(width: 14, height: 16)
                    }
                    .help(isTakingOver ? strings.cancel : strings.preempt)
                    .accessibilityLabel(Text(isTakingOver ? strings.cancel : strings.preempt))
                    .disabled(!actionsEnabled || (!isTakingOver && (source.health == "auth_required" || source.health == "exhausted")))
                    Button(action: onRefresh) {
                        Image(systemName: isBusy ? "ellipsis" : "arrow.clockwise")
                            .frame(width: 14, height: 16)
                    }
                    .help(refreshHelp)
                    .accessibilityLabel(Text(refreshHelp))
                    .disabled(!actionsEnabled || refreshCoolingDown)
                    if isOfficial {
                        Button(action: onRequestReset) {
                            HStack(spacing: 2) {
                                Text(strings.reset)
                                if let count = source.credits?.availableCount {
                                    Text(count, format: .number).monospacedDigit()
                                }
                            }
                            .cmuxFont(size: CGFloat(settings.fontSize - 1.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(strings.resetHelp)
                        .disabled(!actionsEnabled || resetBlocked || (source.credits?.availableCount ?? 0) <= 0)
                    }
                }
            }
            .buttonStyle(.plain)
            .cmuxFont(size: CGFloat(settings.fontSize - 1))
            if isOfficial {
                HStack(alignment: .top, spacing: 10) {
                    if windows.isEmpty {
                        Text(strings.unknown).foregroundStyle(.secondary)
                    } else {
                        ForEach(windows, id: \.name) { window in
                            quotaCell(window)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(strings.balance).cmuxFont(size: CGFloat(settings.fontSize - 1.5)).foregroundStyle(.secondary)
                    Text(balanceLabel)
                        .cmuxFont(size: CGFloat(settings.fontSize + 3), weight: .semibold)
                        .foregroundStyle(isStale ? Color.orange : ((source.balance?.amount ?? 0) > 0 ? Color.green : Color.secondary))
                        .monospacedDigit()
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            if resetBlocked, let resetRequest {
                Text(resetLabel(resetRequest.status))
                    .cmuxFont(size: CGFloat(settings.fontSize - 1.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .cmuxFont(size: CGFloat(settings.fontSize - 1))
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(detailsHelp(at: date))
        .contextMenu {
            if settings.showActions {
                Button(strings.refresh, action: onRefresh)
                    .help(refreshHelp)
                    .disabled(!actionsEnabled || refreshCoolingDown)
                if needsRecovery {
                    Button(strings.recover, action: onRecover).disabled(!actionsEnabled)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }


    private var isStale: Bool {
        isSnapshotStale || source.balance?.stale == true || source.quota?.stale == true
    }

    private var isOfficial: Bool { source.kind == "official" }
    private var actionsEnabled: Bool { settings.enabled && settings.showActions && canAct && !isBusy && !isSnapshotStale }
    private func refreshHelp(at date: Date) -> String {
        var lines = [source.hasRefreshFailure ? strings.refreshFailed : strings.refresh]
        if let retryAt = source.refreshRetryAt, retryAt > date.timeIntervalSince1970 {
            lines.append(strings.nextRefresh(at: retryAt))
        }
        return lines.joined(separator: "\n")
    }
    private var needsRecovery: Bool {
        switch source.health {
        case "cooldown", "proxy_error": return true
        default: return false
        }
    }

    private var displayName: String {
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // User-chosen provider labels are safe; email-shaped account identities are not.
        guard !name.isEmpty, !name.contains("@"), name != source.id else {
            return isOfficial ? strings.official : strings.provider
        }
        return name
    }

    private var healthLabel: String {
        guard source.enabled else { return strings.disabled }
        switch source.health {
        case "ready":
            return source.capacityAvailable == false || source.admission?.acceptingNewConversations == false
                ? strings.unavailable : strings.healthy
        case "cooldown": return strings.cooldown
        case "exhausted": return strings.exhausted
        case "auth_required": return strings.authRequired
        case "proxy_error": return strings.proxyError
        default: return strings.unknown
        }
    }

    private var healthColor: Color {
        guard source.enabled, !isSnapshotStale else { return .secondary }
        switch source.health {
        case "ready":
            return source.capacityAvailable == false || source.admission?.acceptingNewConversations == false
                ? .orange : .green
        case "cooldown", "exhausted": return .orange
        case "auth_required", "proxy_error": return .red
        default: return .secondary
        }
    }

    private var balanceLabel: String {
        guard let balance = source.balance, let amount = balance.amount, amount.isFinite else { return strings.unknown }
        guard let currency = balance.currency, !currency.isEmpty else {
            return amount.formatted(.number.precision(.fractionLength(0...4))) + " · " + strings.currencyUnknown
        }
        var formatted = amount.formatted(.currency(code: currency))
        if let digit = formatted.firstIndex(where: \.isNumber), digit > formatted.startIndex {
            let preceding = formatted[formatted.index(before: digit)]
            if preceding.isLetter || preceding.unicodeScalars.contains(where: { $0.properties.generalCategory == .currencySymbol }) {
                formatted.insert("\u{2009}", at: digit)
            }
        }
        return formatted
    }

    private var quotaWindows: [CodexpressSnapshot.QuotaWindow] {
        var windows = (source.quota?.windows ?? []).filter { $0.name == "primary" || $0.name == "secondary" }
        windows.sort { ($0.windowSeconds ?? .greatestFiniteMagnitude) < ($1.windowSeconds ?? .greatestFiniteMagnitude) }
        if windows.count > 2 { windows.removeSubrange(2...) }
        return windows
    }

    private func quotaCell(_ window: CodexpressSnapshot.QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(quotaLabel(window)).cmuxFont(size: CGFloat(settings.fontSize - 1.5)).foregroundStyle(.secondary)
                if let used = window.usedPercent, used.isFinite {
                    let remaining = max(0, min(100, 100 - used))
                    Text((remaining / 100).formatted(.percent.precision(.fractionLength(0...1))))
                        .cmuxFont(size: CGFloat(settings.fontSize + 3), weight: .semibold)
                        .foregroundStyle(isStale ? Color.secondary : (remaining > 30 ? .green : (remaining > 10 ? .orange : .red)))
                        .monospacedDigit()
                        .help(strings.remaining)
                } else {
                    Text(strings.unknown).foregroundStyle(.secondary)
                }
            }
            if settings.showResetTimes, let timestamp = window.resetAt, timestamp.isFinite {
                Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month(.twoDigits).day().hour().minute())
                    .cmuxFont(size: CGFloat(settings.fontSize - 2))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(strings.resetTime)
            }
        }
    }

    private func quotaLabel(_ window: CodexpressSnapshot.QuotaWindow) -> String {
        if window.windowSeconds == 604_800 { return strings.weekWindow }
        if let seconds = window.windowSeconds, seconds.isFinite, seconds > 0 {
            return String(format: "%gh", seconds / 3600)
        }
        return strings.remaining
    }

    private func detailsHelp(at date: Date) -> String {
        var lines = [healthLabel]
        if isStale { lines.append(strings.stale) }
        if source.balance?.estimated == true { lines.append(strings.estimated) }
        if (source.balance?.unknownSpendRequests ?? 0) > 0 { lines.append(strings.spendPending) }
        if source.credits?.stale == true { lines.append(strings.cards + " · " + strings.stale) }
        if source.hasRefreshFailure || (source.refreshRetryAt ?? 0) > date.timeIntervalSince1970 {
            lines.append(refreshHelp(at: date))
        }
        if let resetRequest { lines.append(resetLabel(resetRequest.status)) }
        return lines.joined(separator: "\n")
    }

    private var resetBlocked: Bool {
        guard let resetRequest else { return false }
        switch resetRequest.status {
        case "completed", "cancelled", "failed": return false
        default: return true
        }
    }

    private func resetLabel(_ status: String) -> String {
        switch status {
        case "pending_confirmation", "presented": return strings.resetPending
        case "pending_verification": return strings.resetVerifying
        case "completed": return strings.resetCompleted
        case "cancelled": return strings.resetCancelled
        case "failed": return strings.resetFailed
        default: return strings.resetUnknown
        }
    }
}
