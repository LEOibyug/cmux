import CmuxTerminalSharing
import CmuxTerminalSizing
import Testing

@Suite struct TuiTerminalSizingStateTests {
    @Test func capabilityGatesSupport() {
        var state = TuiTerminalSizingState()
        state.connectionStarted(capabilities: ["attach-initial-size"])
        #expect(!state.isSupported)
        state.connectionStarted(capabilities: [TuiTerminalSizingState.capability])
        #expect(state.isSupported)
        #expect(!state.supportsViewDetach)
        state.connectionStarted(capabilities: [TuiTerminalSizingState.capability, TuiTerminalSizingState.viewDetachCapability])
        #expect(state.supportsViewDetach)
    }

    @Test func staleStateGenerationsAreIgnored() {
        var relay = TuiTerminalSizingState()
        let current = TerminalSizingState(generation: 5, cols: 80, rows: 24, reason: .latest, owners: [], policy: .latest, participants: [])
        var stale = current
        stale.generation = 4
        stale.cols = 10
        #expect(relay.receive(current))
        #expect(!relay.receive(stale))
        #expect(!relay.receive(current))
        #expect(relay.state == current)
    }

    @Test func reconnectDropsPriorAttachmentAndGeneration() {
        var relay = TuiTerminalSizingState()
        relay.connectionStarted(capabilities: [TuiTerminalSizingState.capability])
        relay.attached(selfParticipantID: "ssh-client-1")
        relay.receive(TerminalSizingState(generation: 5, cols: 80, rows: 24, reason: .latest, owners: [], policy: .latest, participants: []))
        relay.connectionStarted(capabilities: [TuiTerminalSizingState.capability])
        #expect(relay.selfParticipantID == nil)
        #expect(relay.state == nil)
        #expect(relay.receive(TerminalSizingState(generation: 1, cols: 90, rows: 30, reason: .latest, owners: [], policy: .latest, participants: [])))
    }
}
