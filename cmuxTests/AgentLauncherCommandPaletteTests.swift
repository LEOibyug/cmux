import AppKit
import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentLauncherCommandPaletteTests {


    @MainActor
    @Test func commandPaletteAgentLauncherContributionsFollowAvailabilityAndWorkspaceKind() throws {
        let both = ContentView.commandPaletteAgentLauncherContributions(
            availableProviders: [.claude, .codex]
        )
        #expect(both.map(\.commandId) == [
            ContentView.commandPaletteLaunchClaudeTeamsCommandID,
            ContentView.commandPaletteLaunchCodexTeamsCommandID,
        ])

        var localContext = CommandPaletteContextSnapshot()
        localContext.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        localContext.setBool(ContentView.commandPaletteWorkspaceIsRemoteKey, false)
        #expect(both.allSatisfy { $0.when(localContext) })
        #expect(ContentView.commandPaletteAgentLauncherContributions(availableProviders: []).isEmpty)

        var remoteContext = localContext
        remoteContext.setBool(ContentView.commandPaletteWorkspaceIsRemoteKey, true)
        #expect(both.allSatisfy { !$0.when(remoteContext) })

        let codexOnly = ContentView.commandPaletteAgentLauncherContributions(
            availableProviders: [.codex]
        )
        #expect(codexOnly.map(\.commandId) == [
            ContentView.commandPaletteLaunchCodexTeamsCommandID,
        ])
    }



}
