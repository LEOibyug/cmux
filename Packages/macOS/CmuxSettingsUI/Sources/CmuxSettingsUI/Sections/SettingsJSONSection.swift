import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **cmux.json** section with the config path and an external editor action.
@MainActor
public struct SettingsJSONSection: View {
    private let jsonStore: JSONConfigStore
    private let hostActions: SettingsHostActions

    public init(jsonStore: JSONConfigStore, hostActions: SettingsHostActions) {
        self.jsonStore = jsonStore
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json"), section: .settingsJSON)
                .accessibilityIdentifier("SettingsJSONSection")
            SettingsCard {
                userConfigFileRow
            }
        }
    }

    @ViewBuilder
    private var userConfigFileRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:settingsJSON:open-file",
            String(localized: "settings.settingsJSON.file", defaultValue: "User config file"),
            subtitle: String(localized: "settings.settingsJSON.file.subtitle", defaultValue: "Edit cmux-owned app settings, shortcuts, automation, sidebar, notifications, and browser behavior."),
            controlWidth: 330
        ) {
            HStack(spacing: 8) {
                Text(displayPath)
                    .cmuxFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                    hostActions.openConfigInExternalEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsJSONOpenButton")
            }
            .accessibilityIdentifier("SettingsJSONOpenFileRowActions")
        }
    }

    private var displayPath: String {
        let homePath = NSHomeDirectory()
        let fullPath = jsonStore.fileURL.path
        if fullPath.hasPrefix(homePath) {
            return "~" + String(fullPath.dropFirst(homePath.count))
        }
        return fullPath
    }
}
