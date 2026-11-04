import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Observes display and connection preferences while keeping credentials in the secret store.
@MainActor
struct CodexpressSettingsCard: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var interval: DefaultsValueModel<Double>
    @State private var requestCounts: DefaultsValueModel<Bool>
    @State private var resetTimes: DefaultsValueModel<Bool>
    @State private var actions: DefaultsValueModel<Bool>
    @State private var fontSize: DefaultsValueModel<Double>
    @State private var manualConnection: DefaultsValueModel<Bool>
    @State private var managementPort: DefaultsValueModel<Int>
    @State private var apiKey: SecretValueModel
    @State private var portDraft = "17867"
    @State private var apiKeyDraft = ""
    @State private var invalidAPIKey = false

    init(
        defaultsStore: UserDefaultsSettingsStore,
        secretStore: SecretFileStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressEnabled))
        _interval = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressPollIntervalSeconds))
        _requestCounts = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowRequestCounts))
        _resetTimes = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowResetTimes))
        _actions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowActions))
        _fontSize = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressFontSize))
        _manualConnection = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressManualConnection))
        _managementPort = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressManagementPort))
        _apiKey = State(initialValue: SecretValueModel(store: secretStore, key: catalog.sidebar.codexpressManagementAPIKey, errorLog: errorLog))
    }

    var body: some View {
        SettingsCard {
            enabledRow
            SettingsCardDivider()
            connectionRow
            if manualConnection.current {
                SettingsCardDivider()
                portRow
                SettingsCardDivider()
                apiKeyRow
            }
            SettingsCardDivider()
            intervalRow
            SettingsCardDivider()
            requestCountsRow
            SettingsCardDivider()
            resetTimesRow
            SettingsCardDivider()
            actionsRow
            SettingsCardDivider()
            fontSizeRow
        }
        .accessibilityIdentifier("SettingsCodexpressCard")
        .task {
            startSettingsObservation([enabled, interval, requestCounts, resetTimes, actions, fontSize, manualConnection, managementPort, apiKey])
        }
        .onChange(of: managementPort.current, initial: true) { _, value in
            portDraft = String(value)
        }
        .onChange(of: manualConnection.current) { _, _ in
            apiKeyDraft = ""
            invalidAPIKey = false
        }
        .onDisappear { apiKeyDraft = "" }
    }

    private var connectionRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.connection", defaultValue: "Management Connection", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressManualConnection"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-connection",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.connection.subtitle", defaultValue: "Automatic reads Codexpress’s private local configuration. Manual uses only the port and API key saved below, on this Mac.", bundle: .module),
            controlWidth: 196
        ) {
            Picker("", selection: Binding(get: { manualConnection.current }, set: { manualConnection.set($0) })) {
                Text(String(localized: "settings.sidebar.codexpress.connection.automatic", defaultValue: "Automatic", bundle: .module)).tag(false)
                Text(String(localized: "settings.sidebar.codexpress.connection.manual", defaultValue: "Manual", bundle: .module)).tag(true)
            }
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityIdentifier("SettingsCodexpressConnectionPicker")
        }
    }

    private var portRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.managementPort", defaultValue: "Management Port", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressManagementPort"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-management-port",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.managementPort.subtitle", defaultValue: "Use the Management API port shown in Codexpress (1–65535). Default: 17867.", bundle: .module),
            controlWidth: 196
        ) {
            HStack {
                TextField(title, text: $portDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("SettingsCodexpressManagementPortField")
                    .onSubmit { savePort() }
                Button(String(localized: "settings.sidebar.codexpress.connection.save", defaultValue: "Save", bundle: .module)) { savePort() }
                    .disabled(validPort == nil || validPort == managementPort.current)
                    .accessibilityIdentifier("SettingsCodexpressManagementPortSave")
            }
        }
    }

    private var validPort: Int? {
        guard !portDraft.isEmpty, portDraft.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(portDraft), (1...65_535).contains(value) else { return nil }
        return value
    }

    private func savePort() {
        guard let validPort, validPort != managementPort.current else { return }
        managementPort.set(validPort)
    }

    private var apiKeyRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.managementAPIKey", defaultValue: "Management API Key", bundle: .module)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                searchAnchorID: "setting:sidebarAppearance:codexpress-management-key",
                title,
                subtitle: apiKey.current.isEmpty
                    ? String(localized: "settings.sidebar.codexpress.managementAPIKey.missing", defaultValue: "No key saved. Manual mode cannot connect until you save a key.", bundle: .module)
                    : String(localized: "settings.sidebar.codexpress.managementAPIKey.saved", defaultValue: "A key is saved in a separate owner-only file, never in cmux.json or UserDefaults.", bundle: .module),
                controlWidth: 280
            ) {
                HStack(spacing: 8) {
                    SecureField(title, text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("SettingsCodexpressManagementAPIKeyField")
                        .onSubmit { saveAPIKey() }
                    Button(String(localized: "settings.sidebar.codexpress.connection.save", defaultValue: "Save", bundle: .module)) { saveAPIKey() }
                        .disabled(apiKeyDraft.isEmpty)
                        .accessibilityIdentifier("SettingsCodexpressManagementAPIKeySave")
                    if !apiKey.current.isEmpty {
                        Button(String(localized: "settings.sidebar.codexpress.connection.clear", defaultValue: "Clear", bundle: .module)) {
                            apiKeyDraft = ""
                            invalidAPIKey = false
                            apiKey.reset()
                        }
                        .accessibilityIdentifier("SettingsCodexpressManagementAPIKeyClear")
                    }
                }
            }
            if invalidAPIKey {
                SettingsCardNote(String(localized: "settings.sidebar.codexpress.managementAPIKey.invalid", defaultValue: "Use the 16–256 character API key from Codexpress, without spaces or line breaks.", bundle: .module))
            }
        }
    }

    private func saveAPIKey() {
        guard (16...256).contains(apiKeyDraft.utf8.count),
              apiKeyDraft.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            invalidAPIKey = true
            return
        }
        apiKey.set(apiKeyDraft)
        apiKeyDraft = ""
        invalidAPIKey = false
    }

    private var enabledRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.enabled", defaultValue: "Codexpress Status", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressEnabled"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-enabled",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.enabled.subtitle", defaultValue: "Shows the Codexpress card. Turning it off also stops periodic local status requests.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCodexpressEnabledToggle")
                .accessibilityLabel(title)
        }
    }

    private var intervalRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.interval", defaultValue: "Status Interval (Seconds)", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressPollIntervalSeconds"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-poll-interval",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.interval.subtitle", defaultValue: "Checks local status every 1–60 seconds while the sidebar is visible. Does not refresh upstream quota or balance.", bundle: .module),
            controlWidth: 196
        ) {
            Stepper(value: Binding(get: { interval.current }, set: { interval.set($0) }), in: 1...60, step: 1) {
                Text(interval.current, format: .number.precision(.fractionLength(0...1)))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsCodexpressIntervalStepper")
            .accessibilityLabel(title)
        }
    }

    private var requestCountsRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.requestCounts", defaultValue: "Show Active Request Counts", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressShowRequestCounts"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-request-counts",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.requestCounts.subtitle", defaultValue: "Shows each source’s active request count beside its name.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { requestCounts.current }, set: { requestCounts.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCodexpressRequestCountsToggle")
                .accessibilityLabel(title)
        }
    }

    private var resetTimesRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.resetTimes", defaultValue: "Show Quota Reset Times", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressShowResetTimes"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-reset-times",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.resetTimes.subtitle", defaultValue: "Shows reset dates below official quota windows.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { resetTimes.current }, set: { resetTimes.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCodexpressResetTimesToggle")
                .accessibilityLabel(title)
        }
    }

    private var actionsRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.actions", defaultValue: "Show Codexpress Actions", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressShowActions"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-actions",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.actions.subtitle", defaultValue: "Shows open, refresh, takeover, recovery, and reset controls. Hiding them keeps pending operations tracked without resubmitting them.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { actions.current }, set: { actions.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCodexpressActionsToggle")
                .accessibilityLabel(title)
        }
    }

    private var fontSizeRow: some View {
        let title = String(localized: "settings.sidebar.codexpress.fontSize", defaultValue: "Codexpress Font Size (Points)", bundle: .module)
        return SettingsCardRow(
            configurationReview: .json("sidebar.codexpressFontSize"),
            searchAnchorID: "setting:sidebarAppearance:codexpress-font-size",
            title,
            subtitle: String(localized: "settings.sidebar.codexpress.fontSize.subtitle", defaultValue: "Scales the compact header, source names, quota, and balance text together.", bundle: .module),
            controlWidth: 196
        ) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { fontSize.current }, set: { fontSize.set($0) }), in: 8...20, step: 0.5)
                    .frame(width: 120)
                    .accessibilityIdentifier("SettingsCodexpressFontSizeSlider")
                    .accessibilityLabel(title)
                Text(fontSize.current, format: .number.precision(.fractionLength(0...1)))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
