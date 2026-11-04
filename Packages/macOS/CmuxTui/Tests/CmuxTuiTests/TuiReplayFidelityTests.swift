import Testing
import CmuxTui

@Suite struct TuiReplayFidelityTests {
    private let remote = TuiManualIOGrid(columns: 99, rows: 35)!
    private let hidden = TuiManualIOGrid(columns: 60, rows: 6)!

    @Test func replayParsedAtAnotherGridIsRepairedOnceTheGridsMatch() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: hidden)
        fidelity.replayApplied(token: token, local: hidden)
        #expect(!fidelity.needsRepair(local: hidden))
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func replayIsNotRepairedBeforeParserCompletion() {
        var fidelity = TuiReplayFidelity()
        _ = fidelity.replayQueued(remote: remote, local: hidden)
        #expect(!fidelity.needsRepair(local: remote))
    }

    @Test func discardedReplayCanBeRefetchedOnceTheGridMatches() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: hidden)
        fidelity.replayDiscarded(token: token)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func replayParsedAtTheDaemonGridNeedsNoRepair() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: remote)
        fidelity.replayApplied(token: token, local: remote)
        #expect(fidelity.faithfulGrid == remote)
        #expect(!fidelity.needsRepair(local: remote))
    }

    @Test func pendingLocalResizeOnEitherSideOfTheParseIsNotFaithful() {
        var fidelity = TuiReplayFidelity()
        let pendingBefore = fidelity.replayQueued(remote: remote, local: nil)
        fidelity.replayApplied(token: pendingBefore, local: remote)
        #expect(fidelity.needsRepair(local: remote))
        let pendingAfter = fidelity.replayQueued(remote: remote, local: remote)
        fidelity.replayApplied(token: pendingAfter, local: nil)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func completionOfASupersededReplayIsIgnored() {
        var fidelity = TuiReplayFidelity()
        let stale = fidelity.replayQueued(remote: remote, local: remote)
        let current = fidelity.replayQueued(remote: remote, local: hidden)
        fidelity.replayApplied(token: stale, local: remote)
        #expect(!fidelity.needsRepair(local: remote))
        fidelity.replayApplied(token: current, local: hidden)
        #expect(fidelity.faithfulGrid == nil)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func unchangedGridReportDuringParsingKeepsReplayFaithful() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: remote)
        // Pixel-only layout updates report the same terminal dimensions.
        fidelity.localGridChanged(to: remote)
        fidelity.localGridChanged(to: remote)
        fidelity.replayApplied(token: token, local: remote)
        #expect(fidelity.faithfulGrid == remote)
        #expect(!fidelity.needsRepair(local: remote))
    }

    @Test func gridChangeAwayAndBackBeforeReplayCompletionIsNotFaithful() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: remote)
        fidelity.localGridChanged(to: hidden)
        fidelity.localGridChanged(to: remote)
        fidelity.replayApplied(token: token, local: remote)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func localResizeAfterAFaithfulParseInvalidatesIt() {
        var fidelity = TuiReplayFidelity()
        let token = fidelity.replayQueued(remote: remote, local: remote)
        fidelity.replayApplied(token: token, local: remote)
        fidelity.localGridChanged(to: remote)
        #expect(!fidelity.needsRepair(local: remote))
        fidelity.localGridChanged(to: hidden)
        fidelity.localGridChanged(to: remote)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func repairsStopAtTheLimitUntilAFaithfulReplayRefillsThem() {
        var fidelity = TuiReplayFidelity(repairLimit: 2)
        for _ in 0..<2 {
            let token = fidelity.replayQueued(remote: remote, local: hidden)
            fidelity.replayApplied(token: token, local: hidden)
            #expect(fidelity.needsRepair(local: remote))
            fidelity.repairStarted()
        }
        let exhausted = fidelity.replayQueued(remote: remote, local: hidden)
        fidelity.replayApplied(token: exhausted, local: hidden)
        #expect(!fidelity.needsRepair(local: remote))
        let faithful = fidelity.replayQueued(remote: remote, local: remote)
        fidelity.replayApplied(token: faithful, local: remote)
        #expect(fidelity.repairs == 0)
        fidelity.localGridChanged(to: hidden)
        #expect(fidelity.needsRepair(local: remote))
    }

    @Test func noReplayOrAnUnknownDaemonGridNeverRepairs() {
        var fidelity = TuiReplayFidelity()
        #expect(!fidelity.needsRepair(local: remote))
        let token = fidelity.replayQueued(remote: nil, local: remote)
        fidelity.replayApplied(token: token, local: remote)
        #expect(!fidelity.needsRepair(local: remote))
        #expect(!fidelity.needsRepair(local: nil))
    }
}
