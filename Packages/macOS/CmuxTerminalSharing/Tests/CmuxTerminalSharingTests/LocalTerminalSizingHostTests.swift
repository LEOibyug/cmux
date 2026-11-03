import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@Suite struct LocalTerminalSizingHostTests {
    private let me = TerminalSharingIdentity(userID: "u_me", displayName: "Me", deviceName: "Mac")

    private func host(
        mac: TerminalGridSize = TerminalGridSize(cols: 200, rows: 60),
        policy: TerminalSizingPolicy = .latest
    ) -> LocalTerminalSizingHost {
        LocalTerminalSizingHost(
            macParticipant: me.participant(id: "mac:pane", deviceKind: .mac, viewport: mac),
            initialSize: mac,
            policy: policy
        )
    }

    @Test func macAloneIsUncapped() {
        #expect(host().applyTarget == .uncapped)
    }


    /// Detaching the Mac view leaves the terminal's last grid intact and
    /// ignores view resizes and input until reattachment.
    @Test func macViewDetachesWhileTheTerminalKeepsItsGrid() {
        var h = host()
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(me.detachActor), at: Date(timeIntervalSince1970: 0))
        let disconnected = h.disconnect("mac:pane", detachment: detachment)
        #expect(disconnected)
        #expect(h.isDetached("mac:pane"))
        #expect(h.macDetachment == detachment)
        #expect(h.state.participant("mac:pane") == nil)
        #expect(h.state.owners.isEmpty)
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 200, rows: 60)))
        let resized = h.updateMacViewport(TerminalGridSize(cols: 180, rows: 50))
        let typed = h.noteActivity("mac:pane")
        #expect(!resized)
        #expect(!typed)
        #expect(h.state.participant("mac:pane") == nil)
    }

    @Test func macReattachRestoresItsViewWithTheLatestPaneGrid() {
        var h = host()
        _ = h.disconnect("mac:pane", detachment: TerminalSharingDetachment(reason: .disconnectedBy(nil), at: Date()))
        h.updateMacViewport(TerminalGridSize(cols: 180, rows: 50))
        let reattached = h.reattach("mac:pane", asViewer: true)
        #expect(reattached)
        #expect(!h.isDetached("mac:pane"))
        let row = h.state.participant("mac:pane")
        #expect(row?.participant.viewport == TerminalGridSize(cols: 180, rows: 50))
        #expect(row?.participant.countsOverride == false)
        #expect(h.state.owners.isEmpty)
        let again = h.reattach("mac:pane", asViewer: false)
        #expect(!again)
    }

    @Test func macReattachAsParticipantTakesTheGridBack() {
        var h = host()
        _ = h.disconnect("mac:pane", detachment: TerminalSharingDetachment(reason: .disconnectedBy(nil), at: Date()))
        let reattached = h.reattach("mac:pane", asViewer: false)
        #expect(reattached)
        #expect(h.state.owners == ["mac:pane"])
        #expect(h.applyTarget == .uncapped)
    }

}
