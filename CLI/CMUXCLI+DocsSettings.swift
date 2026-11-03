import Foundation

extension CMUXCLI {
    static let docsTopicNames = ["settings", "config", "layout", "ssh", "browser", "vault", "hooks"]

    func runDocsCommand(commandArgs: [String], jsonOutput: Bool) throws {
        let arguments = commandArgs.filter { $0 != "--json" }
        guard arguments.count <= 1 else { throw CLIError(message: "Usage: cmux docs [topic]") }
        guard let topic = arguments.first, !["help", "--help", "-h"].contains(topic) else {
            print(jsonOutput ? jsonString(["topics": Self.docsTopicNames]) : docsUsage())
            return
        }
        guard Self.docsTopicNames.contains(topic), let text = subcommandUsage(topic) else {
            throw CLIError(message: "Unknown documentation topic: \(topic)")
        }
        print(jsonOutput ? jsonString(["topic": topic, "documentation": text]) : text)
    }

    func docsUsage() -> String {
        "Usage: cmux docs [topic]\nLocal command reference: " + Self.docsTopicNames.joined(separator: ", ")
    }
    
    
    static let primarySettingsDisplayPath = "~/.config/cmux/cmux.json"
    static let legacySettingsDisplayPath = "~/.config/cmux/settings.json"
    static let fallbackSettingsDisplayPath = "~/Library/Application Support/com.cmuxterm.app/settings.json"
    static let ghosttyConfigDisplayPath = "~/.config/ghostty/config"

    

    

    

    

    /// Uses the existing CLI bundle and language lookup for workflow prose.
    static func workflowText(_ key: String, _ defaultValue: String) -> String {
        CMUXDiffViewerLocalization.string(key, defaultValue: defaultValue)
    }

    

    

    

    

    

    /// Completion candidates for `cmux docs`, derived from the same table the
    /// runner resolves against so the two cannot drift. Only canonical topics
    /// are offered; the aliases still resolve, but suggesting all of them would
    /// bury the eleven real topics.
    

    /// Completion candidates for `cmux settings <target>` and `cmux settings open
    /// <target>`. Canonical spellings only, matching `settingsTargetRawValue`.
    static let settingsTargetNames: [String] = [
        "app", "themes", "terminal", "sidebar-appearance",
        "custom-sidebars", "automation", "browser", "browser-import",
        "global-hotkey", "keyboard-shortcuts", "workspace-colors",
        "cmux-json", "reset",
    ]

    

    

    

    

    

    

    

    

    func runSettings(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments
        let subcommand = args.first?.lowercased() ?? "open"

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(settingsUsage())
            return
        }

        switch subcommand {
        case "path", "paths":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings path")
            }
            printSettingsPaths(jsonOutput: wantsJSON)
            return
        case "docs", "documentation":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings docs")
            }
            try runDocsCommand(commandArgs: ["settings"], jsonOutput: wantsJSON)
            return
        case "open":
            let targetRaw: String?
            if args.count > 2 {
                throw CLIError(message: "Usage: cmux settings open [target]")
            } else if let rawTarget = args.dropFirst().first {
                guard let target = settingsTargetRawValue(for: rawTarget) else {
                    throw CLIError(message: "Unknown settings target '\(rawTarget)'. Run 'cmux settings --help'.")
                }
                targetRaw = target
            } else {
                targetRaw = nil
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
            return
        default:
            guard let targetRaw = settingsTargetRawValue(for: subcommand) else {
                throw CLIError(message: "Unknown settings subcommand '\(subcommand)'. Run 'cmux settings --help'.")
            }
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings [open [target]|path|docs|<target>]")
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
        }
    }

    func settingsCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let subcommand = parsedArgs.arguments.first?.lowercased() ?? "open"
        return hasHelpRequest(beforeSeparator: parsedArgs.head) ||
            ["path", "paths", "docs", "documentation"].contains(subcommand)
    }

    func settingsUsage() -> String {
        return """
        Usage: cmux settings [open [target]|path|docs|<target>]

        Open cmux Settings, print cmux.json paths, or show settings documentation.

        Subcommands:
          open [target]       Open Settings, optionally to a target section.
          path                Print local cmux.json paths.
          docs                Print the same output as `cmux docs settings`.

        Targets:
          app, themes, terminal, sidebar-appearance,
          custom-sidebars, automation, browser, browser-import,
          global-hotkey, keyboard-shortcuts, shortcuts, workspace-colors,
          cmux-json, json, reset

        Config file:
          \(Self.primarySettingsDisplayPath)
          legacy config: \(Self.legacySettingsDisplayPath)
          legacy app support: \(Self.fallbackSettingsDisplayPath)

        Related (not cmux-owned, but cmux reads it for terminal behavior):
          \(Self.ghosttyConfigDisplayPath)

        Before editing cmux.json:
          Back up any existing cmux.json file to a timestamped .bak copy so the user can revert.

        Reload after editing cmux.json or Ghostty config:
          cmux reload-config   (reloads BOTH and refreshes terminals; no app restart needed)
        """
    }

    private func settingsTargetRawValue(for rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "app", "general":
            return "app"
        case "themes", "theme", "appearance":
            return "themes"
        case "terminal":
            return "terminal"
        case "sidebar", "sidebar-appearance", "sidebarappearance":
            return "sidebarAppearance"
        case "custom-sidebars", "customsidebars":
            return "customSidebars"
        case "automation":
            return "automation"
        case "browser":
            return "browser"
        case "browser-import", "browserimport", "import-browser-data":
            return "browserImport"
        case "global-hotkey", "globalhotkey", "hotkey":
            return "globalHotkey"
        case "keyboard-shortcuts", "keyboardshortcuts", "shortcuts", "keys", "keybindings":
            return "keyboardShortcuts"
        case "workspace-colors", "workspacecolors", "colors":
            return "workspaceColors"
        case "cmux-json", "cmuxjson", "settings-json", "settingsjson", "json", "file", "settings-file":
            return "settingsJSON"
        case "reset":
            return "reset"
        default:
            return nil
        }
    }

    private func openSettingsTarget(
        _ targetRaw: String?,
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        var params: [String: Any] = ["activate": true]
        if let targetRaw {
            params["target"] = targetRaw
        }

        let response = try client.sendV2(method: "settings.open", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let target = (response["target"] as? String) ?? targetRaw ?? "general"
            print("OK target=\(target)")
        }
    }

    func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    func docsSettingsArguments(_ commandArgs: [String]) -> (head: [String], arguments: [String]) {
        let separatorIndex = commandArgs.firstIndex(of: "--")
        let head = separatorIndex.map { Array(commandArgs[..<$0]) } ?? commandArgs
        let tail = separatorIndex.map { Array(commandArgs[commandArgs.index(after: $0)...]) } ?? []
        let headArguments = head.filter { $0 != "--json" }
        return (head, headArguments + tail)
    }

    func hasHelpRequest(beforeSeparator args: [String]) -> Bool {
        let positionalArgs = args.filter { $0 != "--json" }
        return args.contains("--help") || args.contains("-h") || positionalArgs.first?.lowercased() == "help"
    }
}
