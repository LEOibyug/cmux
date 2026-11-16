import SwiftUI
import CmuxControlCenter

struct ControlCenterPreferencesView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterPreference?
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ControlCenterStrings.text("preferenceHint"))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryForegroundColor)
                if !coordinator.snapshot.preferences.isEmpty {
                    Text("\(coordinator.snapshot.preferences.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button {
                    editing = ControlCenterPreference(key: "", value: "")
                } label: {
                    Label(ControlCenterStrings.text("addPreference"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if coordinator.snapshot.preferences.isEmpty {
                ControlCenterEmptyCardView(
                    symbol: "brain",
                    title: ControlCenterStrings.text("preferences"),
                    subtitle: ControlCenterStrings.text("preferenceHint")
                )
                Spacer(minLength: 0)
            } else {
                List(coordinator.snapshot.preferences) { preference in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.accentColor.opacity(0.12))
                                .frame(width: 28, height: 28)
                            Image(systemName: "brain")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                        }
                        .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(preference.key)
                                    .fontWeight(.medium)
                                Text(preference.scope.isEmpty ? ControlCenterStrings.text("global") : preference.scope)
                                    .font(.system(.caption2, design: preference.scope.isEmpty ? .default : .monospaced).weight(.medium))
                                    .foregroundStyle(theme.secondaryForegroundColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                            }
                            Text(preference.value)
                                .font(.callout)
                                .foregroundStyle(theme.foregroundColor)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button(ControlCenterStrings.text("edit")) { editing = preference }
                            .controlSize(.small)
                        Button(ControlCenterStrings.text("remove")) {
                            Task { await coordinator.deletePreference(preference.id) }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.borderColor))
            }
        }
        .sheet(item: $editing) { preference in
            ControlCenterPreferenceEditorView(preference: preference) { updated in
                Task { await coordinator.savePreference(updated) }
            }
            .controlCenterSheetTheme(theme)
        }
    }
}

struct ControlCenterPreferenceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlCenterTheme) private var theme
    @State var preference: ControlCenterPreference
    let save: (ControlCenterPreference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ControlCenterStrings.text("preferences")).font(.headline)
            Form {
                Section {
                    TextField(ControlCenterStrings.text("key"), text: $preference.key)
                    TextField(ControlCenterStrings.text("value"), text: $preference.value)
                    TextField(ControlCenterStrings.text("scope"), text: $preference.scope)
                    Text(ControlCenterStrings.text("scopeHint"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(preference); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preference.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preference.value.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
    }
}

struct ControlCenterConnectionView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        Form {
            Section {
                Text(ControlCenterStrings.text("connectionHint"))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryForegroundColor)
                HStack(spacing: 10) {
                    Button {
                        Task { await coordinator.importCodexpressConnection() }
                    } label: {
                        Label(ControlCenterStrings.text("importCodexpress"), systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("controlCenter.importCodexpress")
                    Text(ControlCenterStrings.text("codexpressImportHint"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
                if !coordinator.isRunning,
                   coordinator.operation?.title == ControlCenterStrings.text("importCodexpress"),
                   let step = coordinator.operation?.steps.first(where: { $0.status == .success }) {
                    Label(step.detail, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("controlCenter.codexpressImportSuccess")
                }
                TextField(ControlCenterStrings.text("baseURL"), text: $coordinator.connection.baseURL)
                SecureField(ControlCenterStrings.text("apiKey"), text: $coordinator.connection.apiKey)
                    .accessibilityIdentifier("controlCenter.apiKey")
                TextField(ControlCenterStrings.text("model"), text: $coordinator.connection.model)
                HStack(spacing: 10) {
                    Button {
                        Task { await coordinator.loadModels() }
                    } label: {
                        Label(ControlCenterStrings.text("queryModels"), systemImage: "arrow.clockwise")
                    }
                    .disabled(coordinator.isRunning)
                    if !coordinator.models.isEmpty {
                        Picker(ControlCenterStrings.text("availableModels"), selection: $coordinator.connection.model) {
                            if !coordinator.models.contains(coordinator.connection.model) {
                                Text(coordinator.connection.model).tag(coordinator.connection.model)
                            }
                            ForEach(coordinator.models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }
            Section {
                TextField(ControlCenterStrings.text("ompExecutable"), text: $coordinator.connection.ompExecutable)
                TextField(ControlCenterStrings.text("defaultDirectory"), text: $coordinator.connection.defaultDirectory)
                Text(ControlCenterStrings.text("executableHint"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            Section {
                HStack {
                    Spacer()
                    Button(ControlCenterStrings.text("saveConnection")) {
                        Task { await coordinator.saveConnection() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled(coordinator.isRunning)
    }
}

struct ControlCenterChatLogSettingsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var confirmsLogClear = false
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label(ControlCenterStrings.text("chatLogs"), systemImage: "externaldrive.badge.timemachine")
                    .font(.subheadline.weight(.semibold))
                LabeledContent(
                    ControlCenterStrings.text("chatLogStorage"),
                    value: ByteCountFormatter.string(fromByteCount: coordinator.chatLogStatistics.storageBytes, countStyle: .file)
                )
                .font(.caption)
                LabeledContent(
                    ControlCenterStrings.text("chatLogConversations"),
                    value: String(coordinator.chatLogStatistics.conversationCount)
                )
                .font(.caption)
                LabeledContent(
                    ControlCenterStrings.text("chatLogEvents"),
                    value: String(coordinator.chatLogStatistics.eventCount)
                )
                .font(.caption)
                Spacer(minLength: 0)
                Button(ControlCenterStrings.text("refresh")) {
                    Task { await coordinator.refreshChatLogStatistics() }
                }
                .controlSize(.small)
                Button(ControlCenterStrings.text("chatLogClear"), role: .destructive) {
                    confirmsLogClear = true
                }
                .controlSize(.small)
                .accessibilityIdentifier("controlCenter.clearChatLogs")
            }
            Text(ControlCenterStrings.text("chatLogHelp"))
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
            if let error = coordinator.chatLogError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderColor)
        )
        .disabled(coordinator.isRunning || coordinator.chatLogsLoading)
        .task { await coordinator.refreshChatLogStatistics() }
        .alert(ControlCenterStrings.text("chatLogClearTitle"), isPresented: $confirmsLogClear) {
            Button(ControlCenterStrings.text("cancel"), role: .cancel) {}
            Button(ControlCenterStrings.text("chatLogClear"), role: .destructive) {
                Task { await coordinator.clearSavedChatLogs() }
            }
        } message: {
            Text(ControlCenterStrings.text("chatLogClearDetail"))
        }
    }
}

struct ControlCenterSettingsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var query = ""
    @Environment(\.controlCenterTheme) private var theme
    private var filtered: [ControlCenterSetting] {
        guard !query.isEmpty else { return coordinator.settings }
        return coordinator.settings.filter { "\($0.id) \($0.title) \($0.detail)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlCenterChatLogSettingsView(coordinator: coordinator)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .font(.system(size: 12, weight: .medium))
                    TextField(ControlCenterStrings.text("searchSettings"), text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.secondaryForegroundColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.inputSurfaceColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.borderColor))

                Button {
                    Task { await coordinator.loadSettings() }
                } label: {
                    Label(ControlCenterStrings.text("refresh"), systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await coordinator.undoLastSetting() }
                } label: {
                    Label(ControlCenterStrings.text("undoSetting"), systemImage: "arrow.uturn.backward")
                }
                .disabled(coordinator.settingUndo.isEmpty || coordinator.isRunning)
            }
            if filtered.isEmpty {
                ControlCenterEmptyCardView(
                    symbol: "slider.horizontal.3",
                    title: ControlCenterStrings.text("settings"),
                    subtitle: ControlCenterStrings.text("empty")
                )
                Spacer(minLength: 0)
            } else {
                List(filtered) { setting in
                    ControlCenterSettingEditorView(setting: setting) { value in
                        Task { await coordinator.setSetting(setting.id, value: value) }
                    }
                    .id(setting.id + String(describing: setting.value))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.borderColor))
            }
        }
        .task { await coordinator.loadSettings() }
    }
}

struct ControlCenterSettingEditorView: View {
    let setting: ControlCenterSetting
    let save: (ControlCenterJSON) -> Void
    @Environment(\.controlCenterTheme) private var theme
    @State private var text: String
    @State private var flag: Bool

    init(setting: ControlCenterSetting, save: @escaping (ControlCenterJSON) -> Void) {
        self.setting = setting
        self.save = save
        _text = State(initialValue: setting.value.stringValue ?? setting.value.numberValue.map { String($0) } ?? "")
        _flag = State(initialValue: setting.value.boolValue ?? false)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(setting.title)
                        .fontWeight(.medium)
                    Text(setting.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.foregroundColor.opacity(0.05), in: Capsule())
                        .textSelection(.enabled)
                }
                Text(setting.detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                switch setting.value {
                case .bool:
                    Toggle(ControlCenterStrings.text("value"), isOn: $flag)
                        .labelsHidden()
                    Button(ControlCenterStrings.text("apply")) { save(.bool(flag)) }
                        .controlSize(.small)
                case .string:
                    if setting.options.isEmpty {
                        TextField(ControlCenterStrings.text("value"), text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                    } else {
                        Picker(ControlCenterStrings.text("value"), selection: $text) {
                            if !setting.options.contains(text) { Text(text).tag(text) }
                            ForEach(setting.options, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    Button(ControlCenterStrings.text("apply")) { save(.string(text)) }
                        .controlSize(.small)
                case .number:
                    TextField(ControlCenterStrings.text("number"), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button(ControlCenterStrings.text("apply")) {
                        if let number = Double(text), number.isFinite { save(.number(number)) }
                    }
                    .controlSize(.small)
                    .disabled(Double(text).map { !$0.isFinite } ?? true)
                case .null:
                    ControlCenterNullableSettingView(save: save)
                case .array, .object:
                    Text(String(describing: setting.value))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ControlCenterNullableSettingView: View {
    let save: (ControlCenterJSON) -> Void
    @State private var type = "value"
    @State private var text = ""
    @State private var flag = false

    var body: some View {
        HStack(spacing: 8) {
            Picker(ControlCenterStrings.text("kind"), selection: $type) {
                Text(ControlCenterStrings.text("value")).tag("value")
                Text(ControlCenterStrings.text("number")).tag("number")
                Text(ControlCenterStrings.text("boolean")).tag("boolean")
            }
            .labelsHidden()
            .frame(width: 100)
            if type == "boolean" {
                Toggle(ControlCenterStrings.text("value"), isOn: $flag)
                    .labelsHidden()
            } else {
                TextField(ControlCenterStrings.text(type), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Button(ControlCenterStrings.text("apply")) {
                switch type {
                case "boolean": save(.bool(flag))
                case "number":
                    if let value = Double(text), value.isFinite { save(.number(value)) }
                default: save(.string(text))
                }
            }
            .controlSize(.small)
            .disabled(type == "number" && (Double(text).map { !$0.isFinite } ?? true))
        }
    }
}
