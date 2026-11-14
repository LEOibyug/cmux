import SwiftUI
import CmuxControlCenter

struct ControlCenterPreferencesView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var editing: ControlCenterPreference?

    var body: some View {
        VStack(alignment: .leading) {
            Text(ControlCenterStrings.text("preferenceHint")).font(.callout).foregroundStyle(.secondary)
            Button(ControlCenterStrings.text("addPreference")) { editing = ControlCenterPreference(key: "", value: "") }
            List(coordinator.snapshot.preferences) { preference in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preference.key).fontWeight(.medium)
                        Text(preference.value).textSelection(.enabled)
                        Text(preference.scope.isEmpty ? ControlCenterStrings.text("global") : preference.scope).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ControlCenterStrings.text("edit")) { editing = preference }
                    Button(ControlCenterStrings.text("remove")) { Task { await coordinator.deletePreference(preference.id) } }
                }
            }
        }
        .sheet(item: $editing) { preference in
            ControlCenterPreferenceEditorView(preference: preference) { updated in
                Task { await coordinator.savePreference(updated) }
            }
        }
    }
}

struct ControlCenterPreferenceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var preference: ControlCenterPreference
    let save: (ControlCenterPreference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ControlCenterStrings.text("preferences")).font(.headline)
            Form {
                TextField(ControlCenterStrings.text("key"), text: $preference.key)
                TextField(ControlCenterStrings.text("value"), text: $preference.value)
                TextField(ControlCenterStrings.text("scope"), text: $preference.scope)
                Text(ControlCenterStrings.text("scopeHint")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { dismiss() }
                Button(ControlCenterStrings.text("save")) { save(preference); dismiss() }
                    .disabled(preference.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preference.value.isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}

struct ControlCenterConnectionView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator

    var body: some View {
        Form {
            Section {
                Text(ControlCenterStrings.text("connectionHint")).foregroundStyle(.secondary)
                Button(ControlCenterStrings.text("importCodexpress")) {
                    Task { await coordinator.importCodexpressConnection() }
                }
                .accessibilityIdentifier("controlCenter.importCodexpress")
                Text(ControlCenterStrings.text("codexpressImportHint")).font(.caption).foregroundStyle(.secondary)
                if !coordinator.isRunning,
                   coordinator.operation?.title == ControlCenterStrings.text("importCodexpress"),
                   let step = coordinator.operation?.steps.first(where: { $0.status == .success }) {
                    Label(step.detail, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("controlCenter.codexpressImportSuccess")
                }
                TextField(ControlCenterStrings.text("baseURL"), text: $coordinator.connection.baseURL)
                SecureField(ControlCenterStrings.text("apiKey"), text: $coordinator.connection.apiKey)
                    .accessibilityIdentifier("controlCenter.apiKey")
                TextField(ControlCenterStrings.text("model"), text: $coordinator.connection.model)
                HStack {
                    Button(ControlCenterStrings.text("queryModels")) { Task { await coordinator.loadModels() } }.disabled(coordinator.isRunning)
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
                Text(ControlCenterStrings.text("executableHint")).font(.caption).foregroundStyle(.secondary)
            }
            Button(ControlCenterStrings.text("saveConnection")) { Task { await coordinator.saveConnection() } }
        }.formStyle(.grouped)
            .disabled(coordinator.isRunning)
    }
}

struct ControlCenterSettingsView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    @State private var query = ""
    private var filtered: [ControlCenterSetting] {
        guard !query.isEmpty else { return coordinator.settings }
        return coordinator.settings.filter { "\($0.id) \($0.title) \($0.detail)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(ControlCenterStrings.text("searchSettings"), text: $query)
                Button(ControlCenterStrings.text("refresh")) { Task { await coordinator.loadSettings() } }
                Button(ControlCenterStrings.text("undoSetting")) { Task { await coordinator.undoLastSetting() } }
            }
            List(filtered) { setting in
                ControlCenterSettingEditorView(setting: setting) { value in
                    Task { await coordinator.setSetting(setting.id, value: value) }
                }
                .id(setting.id + String(describing: setting.value))
            }
        }.task { await coordinator.loadSettings() }
    }
}

struct ControlCenterSettingEditorView: View {
    let setting: ControlCenterSetting
    let save: (ControlCenterJSON) -> Void
    @State private var text: String
    @State private var flag: Bool

    init(setting: ControlCenterSetting, save: @escaping (ControlCenterJSON) -> Void) {
        self.setting = setting
        self.save = save
        _text = State(initialValue: setting.value.stringValue ?? setting.value.numberValue.map { String($0) } ?? "")
        _flag = State(initialValue: setting.value.boolValue ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setting.title).fontWeight(.medium)
            Text(setting.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(setting.detail).font(.callout).foregroundStyle(.secondary)
            HStack {
                switch setting.value {
                case .bool:
                    Toggle(ControlCenterStrings.text("value"), isOn: $flag)
                    Button(ControlCenterStrings.text("apply")) { save(.bool(flag)) }
                case .string:
                    if setting.options.isEmpty {
                        TextField(ControlCenterStrings.text("value"), text: $text)
                    } else {
                        Picker(ControlCenterStrings.text("value"), selection: $text) {
                            if !setting.options.contains(text) { Text(text).tag(text) }
                            ForEach(setting.options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button(ControlCenterStrings.text("apply")) { save(.string(text)) }
                case .number:
                    TextField(ControlCenterStrings.text("number"), text: $text)
                    Button(ControlCenterStrings.text("apply")) {
                        if let number = Double(text), number.isFinite { save(.number(number)) }
                    }.disabled(Double(text).map { !$0.isFinite } ?? true)
                case .null:
                    ControlCenterNullableSettingView(save: save)
                case .array, .object:
                    Text(String(describing: setting.value)).textSelection(.enabled)
                }
            }
        }.padding(.vertical, 6)
    }
}

struct ControlCenterNullableSettingView: View {
    let save: (ControlCenterJSON) -> Void
    @State private var type = "value"
    @State private var text = ""
    @State private var flag = false

    var body: some View {
        HStack {
            Picker(ControlCenterStrings.text("kind"), selection: $type) {
                Text(ControlCenterStrings.text("value")).tag("value")
                Text(ControlCenterStrings.text("number")).tag("number")
                Text(ControlCenterStrings.text("boolean")).tag("boolean")
            }
            if type == "boolean" {
                Toggle(ControlCenterStrings.text("value"), isOn: $flag)
            } else {
                TextField(ControlCenterStrings.text(type), text: $text)
            }
            Button(ControlCenterStrings.text("apply")) {
                switch type {
                case "boolean": save(.bool(flag))
                case "number":
                    if let value = Double(text), value.isFinite { save(.number(value)) }
                default: save(.string(text))
                }
            }.disabled(type == "number" && (Double(text).map { !$0.isFinite } ?? true))
        }
    }
}
