import Foundation
import Testing
import CmuxTui

/// Exercises the transport through its public surface only, the way the app
/// target consumes it after the move.
@Suite struct TuiPackageSurfaceTests {
    @Test func shellQuoteLeavesSafeWordsAndQuotesTheRest() {
        #expect(TuiCommandLine.shellQuote("") == "''")
        #expect(TuiCommandLine.shellQuote("/tmp/cmux.sock") == "/tmp/cmux.sock")
        #expect(TuiCommandLine.shellQuote("it's") == "'it'\\''s'")
    }

    /// A line terminator must never be left bare: the shell would end the
    /// command there and run the rest as a second command.
    @Test(arguments: ["abc\n", "abc\r", "abc\r\n", "a\nb"])
    func shellQuoteQuotesLineTerminators(value: String) {
        #expect(TuiCommandLine.shellQuote(value) == "'\(value)'")
    }

    @Test func gridRejectsDimensionsOutsideTheSupportedRange() {
        #expect(TuiManualIOGrid(columns: 1, rows: 24) == nil)
        #expect(TuiManualIOGrid(columns: 80, rows: 10_001) == nil)
        #expect(TuiManualIOGrid(columns: 80, rows: 24)?.columns == 80)
    }

    @Test func resizeSchedulerKeepsOneRequestInFlightAndSendsTheNewestNext() throws {
        let small = try #require(TuiManualIOGrid(columns: 80, rows: 24))
        let medium = try #require(TuiManualIOGrid(columns: 100, rows: 30))
        let large = try #require(TuiManualIOGrid(columns: 120, rows: 40))
        var scheduler = TuiManualIOResizeScheduler()
        #expect(scheduler.sample(small, canSend: true) == small)
        #expect(scheduler.sample(medium, canSend: true) == nil)
        #expect(scheduler.sample(large, canSend: true) == nil)
        #expect(scheduler.acknowledge(canSend: true) == large)
        #expect(scheduler.lastAcknowledged == small)
    }

    @Test func legacyParserReadsNothingFromMalformedData() {
        #expect(TuiLegacySnapshotParser().protocolVersion(from: Data("not json".utf8)) == nil)
    }

    /// The package policy preserves old identify-capability fallbacks while
    /// rejecting modern daemons that cannot frame incomplete VT sequences.
    @Test func staleReplayCapabilityPolicyKeepsLegacyPeersCompatible() throws {
        let commands = TuiManualIOCommand()
        let current = try #require(commands.setClientInfo(name: "test", kind: "native")["capabilities"] as? [String])
        #expect(!commands.isStaleReplayDaemon(capabilities: current))
        #expect(commands.isStaleReplayDaemon(capabilities: current.filter {
            $0 != TuiManualIOCommand.terminalPendingSequenceCapability
        }))
        #expect(!commands.isStaleReplayDaemon(capabilities: []))
        #expect(!commands.isStaleReplayDaemon(capabilities: ["future-unknown-feature"]))
        for capability in [
            TuiManualIOCommand.viewAttachmentLeaseCapability,
            TuiManualIOCommand.viewAttachmentDetachCapability,
            TuiManualIOCommand.sharedSizingCapability,
            TuiManualIOCommand.sizingViewDetachCapability,
            "terminal-color-overrides-v1",
            "attach-identity-v1",
            "attach-initial-size",
        ] {
            #expect(commands.isStaleReplayDaemon(capabilities: [capability]))
            #expect(!commands.isStaleReplayDaemon(capabilities: [
                capability, TuiManualIOCommand.terminalPendingSequenceCapability,
            ]))
        }
    }
}
