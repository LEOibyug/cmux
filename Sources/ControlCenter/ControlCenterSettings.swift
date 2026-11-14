import CmuxControlCenter
import CmuxFoundation
import CmuxSettings
import Foundation

extension ControlCenterCoordinator {
    // This surface deliberately excludes credentials, automation/access policy, commands,
    // plugin/agent integration and permission-related settings.
    func isSafeSetting(_ id: String) -> Bool {
        let sections: Set<String> = ["app", "terminal", "sidebar", "sidebarAppearance", "paneChrome", "workspaceColors", "workspaceGroups", "markdown", "fileEditor", "canvas"]
        guard let section = id.split(separator: ".").first, sections.contains(String(section)) else { return false }
        let lowered = id.lowercased()
        let excluded = ["password", "secret", "token", "socket", "permission", "security", "trust", "command", "executable", "shell", "environment", "path", "clipboard", "autorestore", "autoresume", "hibernat", "sleepy", "quit", "close", "delete", "external", "link", "hotkey", "runaway", "memoryguard", "restore", "install", "update"]
        return !excluded.contains(where: lowered.contains)
    }

    func settingsRows() throws -> [ControlCenterSetting] {
        guard let runtime = settingsRuntime else { throw ControlCenterHostError.blocked("Settings runtime is not configured.") }
        let schema = CmuxConfigSchemaPathLookup()
        let live = CmuxSettingLiveValues.userDefaults(suiteName: Bundle.main.bundleIdentifier)
        var rows: [ControlCenterSetting] = []
        for key in runtime.catalog.all.sorted(by: { $0.id < $1.id }) where isSafeSetting(key.id) {
            if case .secretFile = key.kind { continue }
            let types = schema.declaredTypes(at: key.id.split(separator: ".").map(String.init))
            guard !types.isEmpty, types.isSubset(of: ["boolean", "string", "number", "integer", "null"]) else { continue }
            let reading = try runtime.jsonStore.reading(at: key.id, liveValues: live)
            guard let effective = reading.effective else { continue }
            let value = try ControlCenterJSON.decode(Data(effective.jsonText.utf8))
            let source = reading.configured == nil ? "Live value or schema default" : "Configured in cmux.json"
            let anchor = runtime.searchIndex.anchorID(forSettingsPath: key.id)
            let title = anchor.flatMap { id in runtime.searchIndex.entries.first { $0.anchorID == id }?.title } ?? key.id
            rows.append(ControlCenterSetting(
                id: key.id,
                title: title,
                detail: "\(source). Type: \(types.sorted().joined(separator: ", ")). Edits preserve unrelated file text; consumers apply through the existing configuration reload.",
                value: value
            ))
        }
        return rows
    }

    func loadSettings() async {
        do { settings = try settingsRows() }
        catch { self.error = error.localizedDescription }
    }

    func applySetting(_ id: String, value: ControlCenterJSON) async throws {
        guard isSafeSetting(id), let runtime = settingsRuntime else {
            throw ControlCenterHostError.blocked("This setting is not exposed for safe Control Center edits. Use ordinary Settings for security or integration changes.")
        }
        guard settings.contains(where: { $0.id == id }) else { throw ControlCenterHostError.blocked("Unknown or non-scalar setting; refresh Settings first.") }
        let object = try JSONSerialization.jsonObject(with: value.data(), options: [.fragmentsAllowed])
        guard let settingValue = CmuxSettingValue(jsonObject: object) else { throw ControlCenterHostError.blocked("Invalid typed setting value.") }
        let result = try await runtime.jsonStore.apply(
            .set(path: id, value: settingValue),
            liveValues: .userDefaults(suiteName: Bundle.main.bundleIdentifier)
        )
        settingUndo.append(contentsOf: result.receipts)
        runtime.hostActions.reloadSettingsFile()
        settings = try settingsRows()
        try await record(ControlCenterStep(title: id, status: .success, detail: "Persisted one typed setting. Conditional undo is available; runtime application is not asserted."))
    }

    func setSetting(_ id: String, value: ControlCenterJSON) async {
        await runOperation(title: "Change \(id)") { try await self.applySetting(id, value: value) }
    }

    func undoSetting() async throws {
        guard let runtime = settingsRuntime, let receipt = settingUndo.last else {
            throw ControlCenterHostError.blocked("No setting edit from this app session is available to undo.")
        }
        _ = try await runtime.jsonStore.undo(receipt)
        settingUndo.removeLast()
        runtime.hostActions.reloadSettingsFile()
        settings = try settingsRows()
        try await record(ControlCenterStep(title: "Undo \(receipt.path)", status: .success, detail: "Restored the prior path value only after checking that this edit still owns it. Unrelated settings were left intact."))
    }

    func undoLastSetting() async {
        await runOperation(title: "Undo setting") { try await self.undoSetting() }
    }

    func groundedHelp(_ query: String) throws -> String {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rows = try settingsRows().filter { row in
            terms.isEmpty || terms.contains { (row.id + " " + row.title + " " + row.detail).lowercased().contains($0) }
        }.prefix(24)
        let settingsText = try rows.map { row in
            let value = String(decoding: try row.value.data(), as: UTF8.self)
            return "\(row.title) (\(row.id)) = \(value). \(row.detail)"
        }.joined(separator: "\n")
        return """
        Local cmux Control Center (this installed build):
        • Sessions searches history-enabled Vault sources, default OMP. OMP task-artifact journals are not separate conversations. Choose an exact result; a live pane is focused, otherwise the indexed session uses its source's resume adapter. OMP held, unknown, moved-away or missing-mount sessions are blocked, never intentionally forked.
        • Favorites open local directories, built-in file previews, HTTP(S) browser workspaces or exact sessions without a model request. Collections launch items in saved order; Retry Failed includes only failed/blocked items from the latest collection receipt. Cancel stops remaining work, not existing workspaces.
        • Create Workspace validates the logical directory and optionally creates missing components, then starts the installed OMP with --cwd. It never uses --continue.
        • Settings edits use the current runtime's typed cmux.json mutation engine. Undo refuses a path changed by another writer. Security, credentials and executable settings are not model tools.
        • Memory is explicit key/value/scope data. Project/collection memories outrank global defaults; the current request outranks memory. Memory never grants permissions. Save/delete is explicit; no automatic learning.
        • Chat renders Markdown and streams responses. Messages normally include the current conversation context; New Chat clears it. The full transcript is not restored after app restart. Ask Before Changes requests approval for each local mutation; Full Access skips those approvals only for supported local tools. Neither mode grants shell, account, macOS permission or security access. Connection/model loading happens only when explicitly requested.
        Current settings relevant to the query:
        \(settingsText.isEmpty ? "No safe scalar setting matches. Search the native Settings window for other options." : settingsText)
        """
    }
}
