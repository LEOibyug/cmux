import CmuxSettings
import Foundation

/// Immutable display preferences shared by sidebar row snapshots and terminal tabs.
struct AgentStatusDisplaySettings: Equatable, Sendable {
    let showInactiveAgentStatus: Bool
    let animateAgentStatus: Bool
    let showAgentStatusInSidebar: Bool
    let showAgentStatusInTabs: Bool

    init(
        showInactiveAgentStatus: Bool = true,
        animateAgentStatus: Bool = true,
        showAgentStatusInTabs: Bool = true,
        showAgentStatusInSidebar: Bool = true
    ) {
        self.showInactiveAgentStatus = showInactiveAgentStatus
        self.animateAgentStatus = animateAgentStatus
        self.showAgentStatusInSidebar = showAgentStatusInSidebar
        self.showAgentStatusInTabs = showAgentStatusInTabs
    }

    init(defaults: UserDefaults) {
        self.init(settings: UserDefaultsSettingsClient(defaults: defaults))
    }

    init(settings: any SettingsReading) {
        let sidebar = SidebarCatalogSection()
        self.init(
            showInactiveAgentStatus: settings.value(for: sidebar.showInactiveAgentStatus),
            animateAgentStatus: settings.value(for: sidebar.animateAgentStatus),
            showAgentStatusInTabs: settings.value(for: sidebar.showAgentStatusInTabs),
            showAgentStatusInSidebar: settings.value(for: sidebar.showAgentStatusInSidebar)
        )
    }

    func allows(_ presentation: AgentStatusPresentation) -> Bool {
        switch presentation.state {
        case .idle, .completed: showInactiveAgentStatus
        case .running, .waiting, .needsInput, .error: true
        }
    }
}
