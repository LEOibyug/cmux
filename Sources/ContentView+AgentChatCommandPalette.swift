import AppKit
import CmuxCommandPalette
import CmuxTerminal
import Foundation

extension ContentView {
    /// Maps built-in palette commands back to their configurable action identifiers.
    func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.newSimulatorPane":
            return CmuxSurfaceTabBarBuiltInAction.newSimulator.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        case Self.commandPaletteCopyActionCommandID(.copyWorkingDirectory):
            return CmuxSurfaceTabBarBuiltInAction.copyWorkingDirectory.configID
        case Self.commandPaletteCopyActionCommandID(.copyProjectRoot):
            return CmuxSurfaceTabBarBuiltInAction.copyProjectRoot.configID
        case Self.commandPaletteCopyActionCommandID(.copyScreen):
            return CmuxSurfaceTabBarBuiltInAction.copyScreen.configID
        default:
            return nil
        }
    }

    /// Palette command id for a built-in copy action, e.g.
    /// `palette.copyWorkingDirectory` for `cmux.copyWorkingDirectory`.
    static func commandPaletteCopyActionCommandID(_ action: CmuxSurfaceTabBarBuiltInAction) -> String {
        "palette." + action.configID.replacingOccurrences(of: "cmux.", with: "")
    }


    /// Palette context key indicating that the selected workspace is remotely managed.
    static let commandPaletteWorkspaceIsRemoteKey = CommandPaletteContextKeys(
        rawValue: "workspace.isRemote"
    )
    static let commandPaletteLaunchClaudeTeamsCommandID = "palette.launchClaudeTeams"
    static let commandPaletteLaunchCodexTeamsCommandID = "palette.launchCodexTeams"

    /// Builds launcher commands from availability already resolved away from the main actor.
    static func commandPaletteAgentLauncherContributions(
        availableProviders: Set<AgentSessionProviderID>
    ) -> [CommandPaletteCommandContribution] {
        let canLaunchFromCurrentWorkspace: (CommandPaletteContextSnapshot) -> Bool = { snapshot in
            snapshot.bool(CommandPaletteContextKeys.hasWorkspace)
                && !snapshot.bool(commandPaletteWorkspaceIsRemoteKey)
        }

        var contributions: [CommandPaletteCommandContribution] = []
        if availableProviders.contains(.claude) {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchClaudeTeamsCommandID,
                title: { _ in
                    String(
                        localized: "menu.help.claudeCodeTeams",
                        defaultValue: "Claude Code Teams"
                    )
                },
                subtitle: { _ in "cmux claude-teams" },
                keywords: ["claude", "claude-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        if availableProviders.contains(.codex) {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchCodexTeamsCommandID,
                title: { _ in
                    String(
                        localized: "menu.help.codexTeams",
                        defaultValue: "Codex Teams"
                    )
                },
                subtitle: { _ in "cmux codex-teams" },
                keywords: ["codex", "codex-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        return contributions
    }

    /// Formats the exact bundled-CLI command injected into the new terminal tab.
    nonisolated static func commandPaletteAgentLauncherShellInput(
        cliURL: URL,
        subcommand: String
    ) -> String {
        "\(cliURL.path.terminalShellEscaped) \(subcommand.terminalShellEscaped)\n"
    }

    /// Registers thin palette handlers that delegate launch ownership to the bundled CLI.
    func registerAgentLauncherCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        registry.register(commandId: Self.commandPaletteLaunchClaudeTeamsCommandID) {
            startCommandPaletteAgentLauncherActivation(provider: .claude, subcommand: "claude-teams")
        }
        registry.register(commandId: Self.commandPaletteLaunchCodexTeamsCommandID) {
            startCommandPaletteAgentLauncherActivation(provider: .codex, subcommand: "codex-teams")
        }
    }

}
