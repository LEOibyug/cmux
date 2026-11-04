import CmuxSettings
import SwiftUI

/// Visibility and ordering controls for information below workspace titles and agent status.
@MainActor
struct SidebarInformationSettingsCard: View {
    private let sidebar: SidebarCatalogSection
    @State private var order: DefaultsValueModel<[String]>
    @State private var description: DefaultsValueModel<Bool>
    @State private var notification: DefaultsValueModel<Bool>
    @State private var branchDirectory: DefaultsValueModel<Bool>
    @State private var pullRequests: DefaultsValueModel<Bool>
    @State private var ports: DefaultsValueModel<Bool>
    @State private var metadata: DefaultsValueModel<Bool>
    @State private var log: DefaultsValueModel<Bool>
    @State private var progress: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        sidebar = catalog.sidebar
        _order = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.detailOrder))
        _description = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showWorkspaceDescription))
        _notification = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showNotificationMessage))
        _branchDirectory = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showBranchDirectory))
        _pullRequests = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPullRequests))
        _ports = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPorts))
        _metadata = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showCustomMetadata))
        _log = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showLog))
        _progress = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showProgress))
    }

    var body: some View {
        let details = SidebarWorkspaceDetail.resolvedOrder(order.current)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json(sidebar.detailOrder.id),
                String(localized: "settings.sidebar.information.title", defaultValue: "Workspace Information", bundle: .module)
            ) {
                EmptyView()
            }
            SettingsCardNote(String(localized: "settings.sidebar.information.note", defaultValue: "When enabled, agent status stays directly below the workspace title. Choose which information appears below it and use the arrows to change its order. Hidden groups keep their position.", bundle: .module))
            ForEach(details, id: \.self) { detail in
                SettingsCardDivider()
                informationRow(detail, isFirst: detail == details.first, isLast: detail == details.last)
            }
        }
        .task {
            let models: [any SettingObservationStarting] = [order, description, notification, branchDirectory, pullRequests, ports, metadata, log, progress]
            models.forEach { $0.startObserving() }
        }
    }

    private func informationRow(_ detail: SidebarWorkspaceDetail, isFirst: Bool, isLast: Bool) -> some View {
        let title = title(for: detail)
        let (key, model) = visibilitySetting(for: detail)
        let moveUpLabel = String.localizedStringWithFormat(
            String(localized: "settings.sidebar.information.moveUp", defaultValue: "Move %@ Up", bundle: .module), title
        )
        let moveDownLabel = String.localizedStringWithFormat(
            String(localized: "settings.sidebar.information.moveDown", defaultValue: "Move %@ Down", bundle: .module), title
        )
        return SettingsCardRow(configurationReview: .json(key.id), title) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Button {
                        move(detail, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isFirst)
                    .accessibilityLabel(moveUpLabel)
                    .help(moveUpLabel)
                    .accessibilityIdentifier("SettingsSidebarInformationMoveUp.\(detail.rawValue)")
                    Button {
                        move(detail, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLast)
                    .accessibilityLabel(moveDownLabel)
                    .help(moveDownLabel)
                    .accessibilityIdentifier("SettingsSidebarInformationMoveDown.\(detail.rawValue)")
                }
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(String.localizedStringWithFormat(
                        String(localized: "settings.sidebar.information.toggleVisible", defaultValue: "Show %@", bundle: .module), title
                    ))
                    .accessibilityIdentifier("SettingsSidebarInformationVisibleToggle.\(detail.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsSidebarInformationRow.\(detail.rawValue)")
    }

    private func move(_ detail: SidebarWorkspaceDetail, offset: Int) {
        var details = SidebarWorkspaceDetail.resolvedOrder(order.current)
        guard let index = details.firstIndex(of: detail), details.indices.contains(index + offset) else { return }
        details.swapAt(index, index + offset)
        order.set(details.map(\.rawValue))
    }

    private func visibilitySetting(for detail: SidebarWorkspaceDetail) -> (DefaultsKey<Bool>, DefaultsValueModel<Bool>) {
        switch detail {
        case .description: (sidebar.showWorkspaceDescription, description)
        case .notification: (sidebar.showNotificationMessage, notification)
        case .branchDirectory: (sidebar.showBranchDirectory, branchDirectory)
        case .pullRequests: (sidebar.showPullRequests, pullRequests)
        case .ports: (sidebar.showPorts, ports)
        case .metadata: (sidebar.showCustomMetadata, metadata)
        case .log: (sidebar.showLog, log)
        case .progress: (sidebar.showProgress, progress)
        }
    }

    private func title(for detail: SidebarWorkspaceDetail) -> String {
        switch detail {
        case .description:
            String(localized: "settings.sidebar.information.description", defaultValue: "Workspace Description", bundle: .module)
        case .notification:
            String(localized: "settings.sidebar.information.notification", defaultValue: "Notifications and Conversation Previews", bundle: .module)
        case .branchDirectory:
            String(localized: "settings.sidebar.information.branchDirectory", defaultValue: "Git Branch and Directory", bundle: .module)
        case .pullRequests:
            String(localized: "settings.sidebar.information.pullRequests", defaultValue: "Pull Requests", bundle: .module)
        case .ports:
            String(localized: "settings.sidebar.information.ports", defaultValue: "Ports", bundle: .module)
        case .metadata:
            String(localized: "settings.sidebar.information.metadata", defaultValue: "Custom Metadata", bundle: .module)
        case .log:
            String(localized: "settings.sidebar.information.log", defaultValue: "Log Messages", bundle: .module)
        case .progress:
            String(localized: "settings.sidebar.information.progress", defaultValue: "Progress", bundle: .module)
        }
    }
}
