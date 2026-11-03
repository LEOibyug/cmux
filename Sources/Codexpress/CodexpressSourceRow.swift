import SwiftUI
import CmuxFoundation

/// A read-only source snapshot; mutations are dispatched by the containing card.
struct CodexpressSourceRow: View {
    let source: CodexpressSnapshot.Source
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayName)
                    .cmuxFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: source.activeRequests > 0 ? "waveform.path" : "circle.fill")
                    .cmuxFont(size: source.activeRequests > 0 ? 13 : 7, weight: .semibold)
                    .foregroundStyle(healthColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: source.activeRequests > 0 && !reduceMotion)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 6) {
                Text(healthLabel)
                    .foregroundStyle(healthColor)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(strings.active)
                Text(source.activeRequests, format: .number)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            if isOfficial {
                quotaLine(strings.shortWindow, window: shortWindow)
                quotaLine(strings.weekWindow, window: weeklyWindow)
                freshness(stale: source.quota?.stale, fetchedAt: source.quota?.fetchedAt, failed: source.quota?.error != nil)
                HStack(spacing: 6) {
                    Text(strings.cards)
                    Spacer(minLength: 0)
                    if let count = source.credits?.availableCount {
                        Text(count, format: .number).monospacedDigit()
                    } else {
                        Text(strings.unknown).foregroundStyle(.secondary)
                    }
                }
                freshness(stale: source.credits?.stale, fetchedAt: source.credits?.fetchedAt, failed: source.credits?.error != nil)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(strings.balance)
                    Spacer(minLength: 0)
                    Text(balanceLabel)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                freshness(
                    stale: source.balance?.status == "unavailable" ? true : source.balance?.stale,
                    fetchedAt: source.balance?.updatedAt,
                    failed: source.balance?.status == "unavailable"
                )
                if source.balance?.estimated == true {
                    Text(strings.estimated).foregroundStyle(.secondary)
                }
                if let pending = source.balance?.unknownSpendRequests, pending > 0 {
                    Text(strings.spendPending).foregroundStyle(.orange)
                }
            }

            if let resetRequest {
                Text(resetLabel(resetRequest.status))
                    .foregroundStyle(resetBlocked ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if isTakingOver {
                    Button(strings.cancel, action: onCancelTakeover)
                        .disabled(!actionsEnabled)
                } else {
                    Button(strings.preempt, action: onTakeOver)
                        .disabled(!actionsEnabled || !source.enabled || source.health == "auth_required" || source.health == "exhausted")
                }
                Spacer(minLength: 0)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .help(strings.refresh)
                .accessibilityLabel(Text(strings.refresh))
                .disabled(!actionsEnabled)
                if needsRecovery {
                    Button(action: onRecover) {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 18, height: 18)
                    }
                    .help(strings.recover)
                    .accessibilityLabel(Text(strings.recover))
                    .disabled(!actionsEnabled || !source.enabled)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if isOfficial {
                Button(action: onRequestReset) {
                    Text(strings.reset).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(strings.resetHelp)
                .disabled(!actionsEnabled || !source.enabled || resetBlocked || (source.credits?.availableCount ?? 0) <= 0)
            }
        }
        .cmuxFont(size: 12)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTakingOver ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var isOfficial: Bool { source.kind == "official" }
    private var actionsEnabled: Bool { canAct && !isBusy && !isSnapshotStale }
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
        return amount.formatted(.currency(code: currency))
    }

    private var shortWindow: CodexpressSnapshot.QuotaWindow? {
        source.quota?.windows
            .lazy
            .filter { ($0.name == "primary" || $0.name == "secondary") && ($0.windowSeconds ?? 0) > 0 && $0.windowSeconds != 604_800 }
            .min { ($0.windowSeconds ?? .infinity) < ($1.windowSeconds ?? .infinity) }
    }

    private var weeklyWindow: CodexpressSnapshot.QuotaWindow? {
        source.quota?.windows.first { ($0.name == "primary" || $0.name == "secondary") && $0.windowSeconds == 604_800 }
    }

    @ViewBuilder
    private func quotaLine(_ label: String, window: CodexpressSnapshot.QuotaWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                Spacer(minLength: 0)
                if let used = window?.usedPercent, used.isFinite {
                    Text(strings.remaining).foregroundStyle(.secondary)
                    Text((max(0, min(100, 100 - used)) / 100).formatted(.percent.precision(.fractionLength(0...1))))
                        .monospacedDigit()
                } else {
                    Text(strings.unknown).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(strings.resetTime)
                Spacer(minLength: 0)
                if let timestamp = window?.resetAt, timestamp.isFinite {
                    Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month(.abbreviated).day().hour().minute())
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                } else {
                    Text(strings.unknown)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func freshness(stale: Bool?, fetchedAt: Double?, failed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isSnapshotStale || stale == true ? strings.stale : (stale == false ? strings.fresh : strings.freshnessUnknown))
                .foregroundStyle(isSnapshotStale || stale == true ? Color.orange : Color.secondary)
            if failed {
                Text(strings.unavailable).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if let fetchedAt, fetchedAt.isFinite {
                Text(Date(timeIntervalSince1970: fetchedAt), format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(2)
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
