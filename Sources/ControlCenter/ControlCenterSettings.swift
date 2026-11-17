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
        let defaultSource = ControlCenterStrings.text("settingDefaultSource")
        for key in runtime.catalog.all.sorted(by: { $0.id < $1.id }) where isSafeSetting(key.id) {
            if case .secretFile = key.kind { continue }
            let types = schema.declaredTypes(at: key.id.split(separator: ".").map(String.init))
            guard !types.isEmpty, types.isSubset(of: ["boolean", "string", "number", "integer", "null"]) else { continue }
            let reading = try runtime.jsonStore.reading(at: key.id, liveValues: live)
            guard let effective = reading.effective else { continue }
            let value = try ControlCenterJSON.decode(Data(effective.jsonText.utf8))
            let source = reading.configured == nil ? defaultSource : "cmux.json"
            let anchor = runtime.searchIndex.anchorID(forSettingsPath: key.id)
            let title = anchor.flatMap { id in runtime.searchIndex.entries.first { $0.anchorID == id }?.title } ?? key.id
            rows.append(ControlCenterSetting(
                id: key.id,
                title: title,
                detail: "\(source) · \(types.sorted().joined(separator: ", "))",
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
        try await record(ControlCenterStep(title: id, status: .success, detail: ControlCenterStrings.text("settingSaved")))
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
        try await record(ControlCenterStep(title: "Undo \(receipt.path)", status: .success, detail: ControlCenterStrings.text("settingRestored")))
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
        • Sessions uses history-enabled Vault sources, default OMP. OMP name/path navigation searches its complete persistent metadata index before limiting output to 500 matches; other sources retain the recent-500 metadata window. search_content:true explicitly searches full transcripts. OMP task-artifact journals are not separate conversations. Exact indexed targets and live ownership checks still apply; held, unknown or missing-mount sessions are blocked, never intentionally forked.
        • archive_directories physically moves explicitly named project folders into an archive parent (default Connection directory/Archived) and archives every associated top-level OMP conversation with remapped cwd. Natural-language chat is the primary entry point. A read-only worker plan shows exact folder moves, conversation IDs/journal paths and counts before one approval; Full Access skips only the prompt. Source/destination scope, no-overwrite same-filesystem moves, ownership and approval digest checks still apply. Single-conversation archive_session remains journal-only. Partial/unknown results retain structured receipts and block further same-turn mutations; refresh reconciles remapped archived manifests without replaying work.
        • Favorites open local directories, built-in file previews, HTTP(S) browser workspaces or exact sessions without a model request. Collections launch items in saved order; Retry Failed includes only failed/blocked items from the latest collection receipt. Cancel stops remaining work, not existing workspaces.
        • Create Workspace validates the logical directory and optionally creates missing components, then starts the installed OMP with --cwd. It never uses --continue.
        • Settings edits use the current runtime's typed cmux.json mutation engine. Undo refuses a path changed by another writer. Security, credentials and executable settings are not model tools.
        • Memory is explicit key/value/scope data. Project/collection memories outrank global defaults; the current request outranks memory. Memory never grants permissions. Save/delete is explicit; no automatic learning.
        • Chat streams Markdown, public reasoning summaries and ordered tool progress/results inline. Add images with the attachment button, paste or drop; choose the model and optional reasoning effort beside the composer. /new and /clear begin a new conversation; Up/Down recall inputs at the composer boundary. Edit or regenerate a user message replaces that turn and later context, never undoing completed actions; a fresh model request still obeys approvals and command admission. Ask Before Changes approves mutations and commands. Full Access skips approval but never command safety checks. Unsupported/dangerous commands remain refused.
        • Complete conversations, images, exact request bodies, model outputs, tool arguments/results, approvals/errors and timestamps are saved locally in owner-only chat-logs.sqlite3. The latest conversation and exact model context restore after relaunch, without replaying tools. API keys and authentication headers are never copied into logs. Settings shows actual log database/sidecar storage usage and a confirmed cleanup action; favorites, collections, explicit memory, connection configuration and separate ordinary operation history are preserved. New Chat resets context, not saved logs.
        • open_command_workspace creates a fresh terminal workspace, changes to the validated logical cwd before running the command, and keeps an interactive shell afterward. Supply literal argv such as ["ssh", "lab-computer"], never shell source. Existing user SSH aliases/configuration are trusted; model-supplied -o/-F options and remote commands are refused, and LocalCommand/RemoteCommand are disabled. Authentication remains in the terminal. Explicit cwd overrides relevant directory memory/context, otherwise Connection's editable default directory is used (new configurations: ~/Work/temp). Missing/unavailable directories are blocked, never created or replaced implicitly. The receipt confirms submission, not command completion. Stop does not close a launched terminal, and there are no automatic retries.
        • bash takes the same admitted literal argv for noninteractive inspection, with an explicit existing logical cwd (default Connection directory) and timeout 1–300 seconds (default 60). SSH must use open_command_workspace. Receipts retain command, cwd, exit status, signal, bounded stdout/stderr, truncation, timeout and partial cancelled output. Stop terminates the owned background command group, not terminal workspaces. Supported commands: ls (readable control-character-escaped output and basic listing options), pwd, literal echo/printf, whoami, hostname, uname, uptime, read-only date, and terminal-only SSH.
        Current settings relevant to the query:
        \(settingsText.isEmpty ? "No safe scalar setting matches. Search the native Settings window for other options." : settingsText)
        """
    }
}
