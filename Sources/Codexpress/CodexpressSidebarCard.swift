import SwiftUI
import CmuxFoundation

/// Bounded native footer, observing only while a hosting sidebar is visible.
struct CodexpressSidebarCard: View {
    let coordinator: CodexpressCoordinator
    let settings: CodexpressSettingsSnapshot
    let openCodexpress: () -> Void

    @AppStorage("codexpressSidebarExpanded") private var isExpanded = true
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    private let strings = CodexpressPanelStrings()

    var body: some View {
        Group {
            if settings.enabled {
                if let remote = coordinator.remote {
                    TimelineView(.periodic(from: .now, by: 30)) { clock in
                        card(isStale: remote.isStale(at: clock.date))
                    }
                } else {
                    card(isStale: coordinator.connectionError != nil)
                }
            }
        }
        .onChange(of: settings) { _, next in coordinator.applySettings(next) }
        .task {
            coordinator.applySettings(settings)
            await coordinator.observe()
        }
    }

    private func card(isStale: Bool) -> some View {
        let sources = coordinator.snapshot.map { orderedSources($0.sources) } ?? []
        let generation = coordinator.connectionGeneration
        return VStack(alignment: .leading, spacing: 7) {
            header(isStale: isStale)
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if let remote = coordinator.remote {
                            if let timestamp = remote.fetchedAt {
                                HStack(spacing: 4) {
                                    if isStale { Text(strings.stale) }
                                    Text(timestamp, format: .dateTime.year().month().day().hour().minute().second())
                                }
                                .foregroundStyle(isStale ? Color.orange : .secondary)
                            } else if remote.snapshot != nil {
                                Text(strings.snapshotTimeUnknown).foregroundStyle(.orange)
                            }
                        }
                        if let error = coordinator.connectionError {
                            Text(strings.message(for: error))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if coordinator.snapshot != nil {
                                Text(strings.cached).foregroundStyle(.orange)
                            }
                        }
                        if coordinator.hasReadGateway, coordinator.gateway.isLocal, let error = coordinator.actionError {
                            HStack(alignment: .top, spacing: 6) {
                                Text(strings.message(for: error))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if !coordinator.actionsBlockedAfterConnectionChange {
                                    Button(action: coordinator.dismissActionError) {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help(strings.dismiss)
                                    .accessibilityLabel(Text(strings.dismiss))
                                }
                            }
                        }
                        if let snapshot = coordinator.snapshot {
                            if sources.isEmpty {
                                Text(strings.noSources).foregroundStyle(.secondary)
                            }
                            ForEach(sources, id: \.id) { source in
                                if source.id != sources.first?.id { Divider() }
                                CodexpressSourceRow(
                                    source: source,
                                    settings: settings,
                                    isReadOnly: !coordinator.gateway.isLocal,
                                    isTakingOver: snapshot.manualRoute?.sourceID == source.id,
                                    isBusy: coordinator.activeSourceIDs.contains(source.id),
                                    canAct: snapshot.running && !coordinator.actionsBlockedAfterConnectionChange,
                                    isSnapshotStale: isStale,
                                    resetRequest: coordinator.resetRequests[source.id],
                                    onTakeOver: { coordinator.submit(for: generation) { await coordinator.takeOver(source.id) } },
                                    onCancelTakeover: { coordinator.submit(for: generation) { await coordinator.cancelTakeover() } },
                                    onRecover: { coordinator.submit(for: generation) { await coordinator.recover(source.id) } },
                                    onRefresh: { coordinator.submit(for: generation) { await coordinator.refresh(source) } },
                                    onRequestReset: { coordinator.submit(for: generation) { await coordinator.requestReset(source.id) } }
                                )
                            }
                        } else if coordinator.connectionError == nil {
                            Text(statusLabel).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: contentHeight(for: sources))
            }
        }
        .cmuxFont(size: CGFloat(settings.fontSize - 1))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityIdentifier("CodexpressSidebarCard")
    }

    private func header(isStale: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .cmuxFont(size: CGFloat(settings.fontSize - 1), weight: .semibold)
                    Circle()
                        .fill(isStale ? .orange : statusColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(coordinator.remote != nil ? strings.remoteTitle : strings.title)
                        .cmuxFont(size: CGFloat(settings.fontSize + 2), weight: .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? strings.collapse : strings.expand)
            .accessibilityLabel(Text(isExpanded ? strings.collapse : strings.expand))
            .accessibilityValue(Text(statusLabel))
            if settings.showActions && coordinator.gateway.isLocal {
                Button {
                    Task { await coordinator.refreshLocal() }
                } label: {
                    Image(systemName: coordinator.connectionError != nil ? "exclamationmark.triangle" : (coordinator.isUpdating ? "ellipsis" : "arrow.clockwise"))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(coordinator.isUpdating)
                .help(strings.refresh)
                .accessibilityLabel(Text(strings.refresh))
            }
            if settings.showActions {
                Button(action: openCodexpress) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(strings.open)
                .accessibilityLabel(Text(strings.open))
            }
        }
        .help([statusLabel, coordinator.snapshot.map(modeLabel)].compactMap { $0 }.joined(separator: " · "))
    }

    private func contentHeight(for sources: [CodexpressSnapshot.Source]) -> CGFloat {
        let rowHeight = sources.reduce(CGFloat.zero) { $0 + ($1.kind == "official" ? 56 : 40) }
        let separators = CGFloat(max(0, sources.count - 1)) * 7
        let errorHeight: CGFloat = coordinator.connectionError != nil || coordinator.actionError != nil ? 50 : 0
        let fontScale = CGFloat(settings.fontSize) / 11
        let timestampHeight: CGFloat = coordinator.remote.map { $0.fetchedAt != nil || $0.snapshot != nil } == true ? 18 : 0
        return min(230, max(36, (rowHeight + separators + timestampHeight) * fontScale * CGFloat(magnification) / 100 + errorHeight))
    }

    private var statusLabel: String {
        guard coordinator.hasReadGateway else { return strings.connecting }
        if let error = coordinator.connectionError { return strings.message(for: error) }
        if case .unavailable = coordinator.gateway { return strings.cacheUnavailable }
        if let remote = coordinator.remote, remote.snapshot == nil { return strings.noRemoteSnapshot }
        if coordinator.isUpdating { return strings.syncing }
        guard let snapshot = coordinator.snapshot else { return strings.connecting }
        return snapshot.running ? strings.running : strings.stopped
    }

    private var statusColor: Color {
        if coordinator.connectionError != nil { return .orange }
        guard let snapshot = coordinator.snapshot else { return .secondary }
        return snapshot.running ? .green : .secondary
    }

    private func modeLabel(_ snapshot: CodexpressSnapshot) -> String {
        if snapshot.manualRoute != nil { return strings.manualMode }
        switch snapshot.mode {
        case "auto": return strings.automaticMode
        case "fixed": return strings.fixedMode
        default: return strings.unknownMode
        }
    }

    private func orderedSources(_ sources: [CodexpressSnapshot.Source]) -> [CodexpressSnapshot.Source] {
        sources.filter { $0.enabled && $0.showInCmux }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }
    }
}
