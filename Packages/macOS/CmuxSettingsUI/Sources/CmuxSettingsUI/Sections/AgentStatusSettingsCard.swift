import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Controls agent badge visibility and motion across workspace rows and terminal tabs.
@MainActor
struct AgentStatusSettingsCard: View {
    @State private var showInactive: DefaultsValueModel<Bool>
    @State private var animate: DefaultsValueModel<Bool>
    @State private var showInTabs: DefaultsValueModel<Bool>
    @State private var showInSidebar: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _showInactive = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showInactiveAgentStatus))
        _animate = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.animateAgentStatus))
        _showInTabs = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showAgentStatusInTabs))
        _showInSidebar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showAgentStatusInSidebar))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("sidebar.showAgentStatusInSidebar"),
                String(localized: "settings.sidebar.showAgentStatusInSidebar", defaultValue: "Show Agent Status in Sidebar", bundle: .module),
                subtitle: String(localized: "settings.sidebar.showAgentStatusInSidebar.subtitle", defaultValue: "Show agent status badges directly below workspace titles.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { showInSidebar.current }, set: { showInSidebar.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsShowAgentStatusInSidebarToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("sidebar.showInactiveAgentStatus"),
                String(localized: "settings.sidebar.showInactiveAgentStatus", defaultValue: "Show Completed Agent Status", bundle: .module),
                subtitle: String(localized: "settings.sidebar.showInactiveAgentStatus.subtitle", defaultValue: "Keep Done badges and numeric indicators while viewing a workspace. Clear them when you leave after viewing, mark it as read, or the same pane starts a new task and Working replaces Done. Running, waiting for input, and error badges are unaffected.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { showInactive.current }, set: { showInactive.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsShowInactiveAgentStatusToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("sidebar.animateAgentStatus"),
                String(localized: "settings.sidebar.animateAgentStatus", defaultValue: "Animate Agent Status", bundle: .module),
                subtitle: String(localized: "settings.sidebar.animateAgentStatus.subtitle", defaultValue: "Animate running badges in the sidebar and tabs. Reduce Motion always disables animation.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { animate.current }, set: { animate.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAnimateAgentStatusToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("sidebar.showAgentStatusInTabs"),
                String(localized: "settings.sidebar.showAgentStatusInTabs", defaultValue: "Show Agent Status in Tabs", bundle: .module),
                subtitle: String(localized: "settings.sidebar.showAgentStatusInTabs.subtitle", defaultValue: "Show agent status badges beside terminal tab titles.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { showInTabs.current }, set: { showInTabs.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsShowAgentStatusInTabsToggle")
            }
        }
        .task {
            showInactive.startObserving()
            animate.startObserving()
            showInTabs.startObserving()
            showInSidebar.startObserving()
        }
    }
}
