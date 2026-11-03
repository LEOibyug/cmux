import Testing
@testable import CmuxWorkspaces

@Suite struct PanelShellActivityStateTests {
    /// Raw values arrive over the control socket and live in session
    /// snapshots; round-tripping must stay stable.
    @Test func rawValuesRoundTrip() {
        #expect(PanelShellActivityState(rawValue: "unknown") == .unknown)
        #expect(PanelShellActivityState(rawValue: "promptIdle") == .promptIdle)
        #expect(PanelShellActivityState(rawValue: "commandRunning") == .commandRunning)
        #expect(PanelShellActivityState(rawValue: "bogus") == nil)
        #expect(PanelShellActivityState.promptIdle.rawValue == "promptIdle")
        #expect(PanelShellActivityState.commandRunning.rawValue == "commandRunning")
    }
}

@Suite struct WorkspacePendingTerminalInputReasonTests {
    /// Parity with the legacy `WorkspacePendingTerminalInputPolicy.timeout(for:)`.
    @Test func configurationCommandTimeoutMatchesLegacyPolicy() {
        #expect(WorkspacePendingTerminalInputReason.configurationCommand.timeout == 3.0)
    }
}
