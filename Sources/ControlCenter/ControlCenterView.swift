import SwiftUI
import CmuxControlCenter

enum ControlCenterSection: String, CaseIterable, Identifiable {
    case chat, sessions, favorites, collections, workspace, preferences, settings, history, connection
    var id: String { rawValue }
    var title: String { ControlCenterStrings.text(rawValue) }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "clock"
        case .favorites: return "bookmark"
        case .collections: return "square.stack"
        case .workspace: return "plus.rectangle"
        case .preferences: return "brain"
        case .settings: return "slider.horizontal.3"
        case .history: return "list.bullet.rectangle"
        case .connection: return "network"
        }
    }
}

struct ControlCenterView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    let isVisible: Bool
    @State private var section: ControlCenterSection = .chat

    private var busy: Bool { coordinator.isRunning || coordinator.activeChatTurnID != nil }

    var body: some View {
        ZStack {
            ControlCenterChatView(coordinator: coordinator, isVisible: isVisible && section == .chat) { section = $0 }
                .opacity(section == .chat ? 1 : 0)
                .allowsHitTesting(section == .chat)
                .accessibilityHidden(section != .chat)
            if section != .chat {
                VStack(spacing: 0) {
                    auxiliaryHeader
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = coordinator.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                                .accessibilityIdentifier("controlCenter.error")
                        }
                        if coordinator.isRunning {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(coordinator.operation?.title ?? ControlCenterStrings.text("operation"))
                                Spacer()
                                Button(ControlCenterStrings.text("cancel")) { coordinator.cancel() }
                            }
                        }
                        auxiliaryContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("ControlCenterMainContent")
        .task { await coordinator.load() }
        .onChange(of: coordinator.pendingApproval?.id) { _, id in
            if id != nil { section = .chat }
        }
        .onChange(of: coordinator.chatPresentationID) { _, _ in section = .chat }
    }

    private var auxiliaryHeader: some View {
        HStack(spacing: 12) {
            Button { section = .chat } label: {
                Label(ControlCenterSection.chat.title, systemImage: "chevron.left")
            }
            .disabled(busy)
            Text(section.title).font(.headline)
            Spacer()
            Menu {
                ForEach(ControlCenterSection.allCases.filter { $0 != .chat }) { item in
                    Button { section = item } label: { Label(item.title, systemImage: item.symbol) }
                }
            } label: { Label(ControlCenterStrings.text("chatBrowse"), systemImage: "ellipsis.circle") }
            .disabled(busy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var auxiliaryContent: some View {
        switch section {
        case .chat: EmptyView()
        case .sessions: ControlCenterSessionsView(coordinator: coordinator)
        case .favorites: ControlCenterFavoritesView(coordinator: coordinator)
        case .collections: ControlCenterCollectionsView(coordinator: coordinator)
        case .workspace: ControlCenterWorkspaceView(coordinator: coordinator)
        case .preferences: ControlCenterPreferencesView(coordinator: coordinator)
        case .settings: ControlCenterSettingsView(coordinator: coordinator)
        case .history: ControlCenterHistoryView(coordinator: coordinator)
        case .connection: ControlCenterConnectionView(coordinator: coordinator)
        }
    }
}


struct ControlCenterOperationCardView: View {
    let operation: ControlCenterOperation

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(operation.title).font(.headline)
                Text(operation.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                ForEach(operation.steps) { step in
                    HStack(alignment: .top) {
                        Image(systemName: statusIcon(step.status))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).fontWeight(.medium)
                            Text(ControlCenterStrings.text(step.status.rawValue)).font(.caption).foregroundStyle(.secondary)
                            Text(step.detail).font(.callout).textSelection(.enabled)
                        }
                        Spacer()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusIcon(_ status: ControlCenterStep.Status) -> String {
        switch status {
        case .success: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .blocked: return "hand.raised"
        case .cancelled: return "stop.circle"
        }
    }
}

struct ControlCenterHistoryView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if coordinator.snapshot.operations.isEmpty { Text(ControlCenterStrings.text("empty")) }
                ForEach(coordinator.snapshot.operations) { operation in
                    ControlCenterOperationCardView(operation: operation)
                }
            }
        }
    }
}
