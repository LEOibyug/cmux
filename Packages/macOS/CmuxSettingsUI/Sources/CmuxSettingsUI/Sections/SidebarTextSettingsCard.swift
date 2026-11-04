import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Independent text sizes and wrapping limits backed by the shared settings store.
@MainActor
struct SidebarTextSettingsCard: View {
    private let sidebar: SidebarCatalogSection
    @State private var title: DefaultsValueModel<Double>
    @State private var status: DefaultsValueModel<Double>
    @State private var description: DefaultsValueModel<Double>
    @State private var branch: DefaultsValueModel<Double>
    @State private var directory: DefaultsValueModel<Double>
    @State private var auxiliary: DefaultsValueModel<Double>
    @State private var lines: DefaultsValueModel<Int>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        sidebar = catalog.sidebar
        _title = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.titleFontSize))
        _status = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.agentStatusFontSize))
        _description = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.descriptionFontSize))
        _branch = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.branchFontSize))
        _directory = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.directoryFontSize))
        _auxiliary = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.auxiliaryFontSize))
        _lines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.informationLineLimit))
    }

    var body: some View {
        SettingsCard {
            fontRow(String(localized: "settings.sidebar.text.title", defaultValue: "Workspace Title Size", bundle: .module), key: sidebar.titleFontSize, model: title)
            SettingsCardDivider()
            fontRow(String(localized: "settings.sidebar.text.status", defaultValue: "Agent Status Size", bundle: .module), key: sidebar.agentStatusFontSize, model: status)
            SettingsCardDivider()
            fontRow(String(localized: "settings.sidebar.text.description", defaultValue: "Description Size", bundle: .module), key: sidebar.descriptionFontSize, model: description)
            SettingsCardDivider()
            fontRow(String(localized: "settings.sidebar.text.branch", defaultValue: "Git Branch Size", bundle: .module), key: sidebar.branchFontSize, model: branch)
            SettingsCardDivider()
            fontRow(String(localized: "settings.sidebar.text.directory", defaultValue: "Directory Size", bundle: .module), key: sidebar.directoryFontSize, model: directory)
            SettingsCardDivider()
            fontRow(String(localized: "settings.sidebar.text.auxiliary", defaultValue: "Auxiliary Information Size", bundle: .module), key: sidebar.auxiliaryFontSize, model: auxiliary)
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json(sidebar.informationLineLimit.id),
                String(localized: "settings.sidebar.text.lines", defaultValue: "Information Line Limit", bundle: .module),
                controlWidth: 120
            ) {
                Stepper("\(lines.current)", value: Binding(get: { lines.current }, set: { lines.set($0) }), in: 1...6)
                    .accessibilityIdentifier("SettingsSidebarInformationLineLimit")
            }
            SettingsCardNote(String(localized: "settings.sidebar.text.note", defaultValue: "Set sizes independently; sidebar font scaling and global magnification still apply. Each field wraps up to the line limit, then truncates.", bundle: .module))
        }
        .task {
            let models: [any SettingObservationStarting] = [title, status, description, branch, directory, auxiliary, lines]
            models.forEach { $0.startObserving() }
        }
    }

    private func fontRow(_ title: String, key: DefaultsKey<Double>, model: DefaultsValueModel<Double>) -> some View {
        SettingsCardRow(configurationReview: .json(key.id), title, controlWidth: 120) {
            Stepper(value: Binding(get: { model.current }, set: { model.set($0) }), in: 8...24, step: 0.5) {
                Text(model.current.formatted(.number.precision(.fractionLength(0...1))))
                    .monospacedDigit()
            }
            .accessibilityLabel(title)
            .accessibilityIdentifier("Settings" + key.userDefaultsKey)
        }
    }
}
