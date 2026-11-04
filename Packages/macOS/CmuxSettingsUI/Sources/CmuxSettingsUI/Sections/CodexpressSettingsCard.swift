import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Observes Codexpress display preferences without accessing its private credentials.
@MainActor
struct CodexpressSettingsCard: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var interval: DefaultsValueModel<Double>
    @State private var requestCounts: DefaultsValueModel<Bool>
    @State private var resetTimes: DefaultsValueModel<Bool>
    @State private var actions: DefaultsValueModel<Bool>
    @State private var fontSize: DefaultsValueModel<Double>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressEnabled))
        _interval = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressPollIntervalSeconds))
        _requestCounts = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowRequestCounts))
        _resetTimes = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowResetTimes))
        _actions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressShowActions))
        _fontSize = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.codexpressFontSize))
    }

    var body: some View {
        SettingsCard {
            enabledRow
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
            startSettingsObservation([enabled, interval, requestCounts, resetTimes, actions, fontSize])
        }
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
