import SwiftUI
import CmuxControlCenter

struct ControlCenterView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var section: Section? = .operation

    private enum Section: String, CaseIterable, Identifiable {
        case operation, sessions, favorites, collections, workspace, preferences, settings, history, connection
        var id: String { rawValue }
        var title: String { ControlCenterStrings.text(rawValue) }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Text(item.title).tag(item)
            }
            .navigationTitle(ControlCenterStrings.text("title"))
            .frame(minWidth: 165)
        } detail: {
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
                Group {
                    switch section ?? .operation {
                    case .operation: ControlCenterOperationView(coordinator: coordinator)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(20)
            .navigationTitle(ControlCenterStrings.text("title"))
            .navigationSubtitle((section ?? .operation).title)
        }
        .frame(minWidth: 800, minHeight: 560)
        .task { await coordinator.load() }
    }
}

struct ControlCenterOperationView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ControlCenterStrings.text("operationHint")).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 150)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel(ControlCenterStrings.text("request"))
                .accessibilityIdentifier("controlCenter.request")
            HStack {
                Button(ControlCenterStrings.text("run")) { submit(followUp: false) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isRunning)
                Button(ControlCenterStrings.text("followUp")) { submit(followUp: true) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.operation == nil || coordinator.isRunning)
                Button(ControlCenterStrings.text("newOperation")) { coordinator.resetContext(); prompt = "" }
                    .disabled(coordinator.isRunning)
                Spacer()
                if coordinator.isRunning { ProgressView().controlSize(.small) }
                Button(ControlCenterStrings.text("cancel")) { coordinator.cancel() }.disabled(!coordinator.isRunning)
            }
            if coordinator.connection.model.isEmpty {
                Text(ControlCenterStrings.text("offlineHint")).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !coordinator.output.isEmpty {
                        Text(coordinator.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let operation = coordinator.operation { ControlCenterOperationCardView(operation: operation) }
                }
            }
        }
    }

    private func submit(followUp: Bool) {
        let request = prompt
        Task { await coordinator.submit(request, followUp: followUp) }
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
