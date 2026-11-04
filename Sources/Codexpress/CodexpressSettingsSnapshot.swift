import CmuxSettings
import Foundation

/// Immutable presentation, cadence, and non-secret connection preferences.
struct CodexpressSettingsSnapshot: Equatable, Sendable {
    let enabled: Bool
    let pollIntervalSeconds: Double
    let showRequestCounts: Bool
    let showResetTimes: Bool
    let showActions: Bool
    let fontSize: Double
    let manualConnection: Bool
    let managementPort: Int

    init(catalog: SidebarCatalogSection = .init()) {
        self.init(
            enabled: catalog.codexpressEnabled.defaultValue,
            pollIntervalSeconds: catalog.codexpressPollIntervalSeconds.defaultValue,
            showRequestCounts: catalog.codexpressShowRequestCounts.defaultValue,
            showResetTimes: catalog.codexpressShowResetTimes.defaultValue,
            showActions: catalog.codexpressShowActions.defaultValue,
            fontSize: catalog.codexpressFontSize.defaultValue,
            manualConnection: catalog.codexpressManualConnection.defaultValue,
            managementPort: catalog.codexpressManagementPort.defaultValue
        )
    }

    init(defaults: UserDefaults, catalog: SidebarCatalogSection = .init()) {
        let client = UserDefaultsSettingsClient(defaults: defaults)
        self.init(
            enabled: client.value(for: catalog.codexpressEnabled),
            pollIntervalSeconds: client.value(for: catalog.codexpressPollIntervalSeconds),
            showRequestCounts: client.value(for: catalog.codexpressShowRequestCounts),
            showResetTimes: client.value(for: catalog.codexpressShowResetTimes),
            showActions: client.value(for: catalog.codexpressShowActions),
            fontSize: client.value(for: catalog.codexpressFontSize),
            manualConnection: client.value(for: catalog.codexpressManualConnection),
            managementPort: client.value(for: catalog.codexpressManagementPort)
        )
    }

    init(
        enabled: Bool,
        pollIntervalSeconds: Double,
        showRequestCounts: Bool,
        showResetTimes: Bool,
        showActions: Bool,
        fontSize: Double,
        manualConnection: Bool = false,
        managementPort: Int = 17867
    ) {
        let catalog = SidebarCatalogSection()
        self.enabled = enabled
        self.pollIntervalSeconds = pollIntervalSeconds.isFinite
            ? min(60, max(1, pollIntervalSeconds)) : catalog.codexpressPollIntervalSeconds.defaultValue
        self.showRequestCounts = showRequestCounts
        self.showResetTimes = showResetTimes
        self.showActions = showActions
        self.fontSize = fontSize.isFinite
            ? min(20, max(8, fontSize)) : catalog.codexpressFontSize.defaultValue
        self.manualConnection = manualConnection
        self.managementPort = managementPort
    }
}
