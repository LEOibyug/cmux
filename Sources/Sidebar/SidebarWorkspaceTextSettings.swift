import CmuxSettings
import CoreGraphics
import Foundation

/// Immutable text preferences resolved before crossing the sidebar row boundary.
struct SidebarWorkspaceTextSettings: Equatable {
    let title: CGFloat
    let agentStatus: CGFloat
    let description: CGFloat
    let branch: CGFloat
    let directory: CGFloat
    let auxiliary: CGFloat
    let lineLimit: Int

    init(defaults: UserDefaults? = nil) {
        let sidebar = SidebarCatalogSection()
        let reader = defaults.map { UserDefaultsSettingsClient(defaults: $0) }
        func size(_ key: DefaultsKey<Double>) -> CGFloat {
            let value = reader?.value(for: key) ?? key.defaultValue
            return CGFloat(value.isFinite ? min(max(value, 8), 24) : key.defaultValue)
        }
        title = size(sidebar.titleFontSize)
        agentStatus = size(sidebar.agentStatusFontSize)
        description = size(sidebar.descriptionFontSize)
        branch = size(sidebar.branchFontSize)
        directory = size(sidebar.directoryFontSize)
        auxiliary = size(sidebar.auxiliaryFontSize)
        lineLimit = min(max(reader?.value(for: sidebar.informationLineLimit) ?? sidebar.informationLineLimit.defaultValue, 1), 6)
    }
}
