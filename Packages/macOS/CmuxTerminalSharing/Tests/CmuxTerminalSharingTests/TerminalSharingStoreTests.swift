import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@MainActor
private final class FakeController: TerminalSharingSurfaceControlling {
    var host: TerminalSizingEngine
    var disconnected: [String] = []
    var activity = 0
    var reattached: [Bool] = []
    let store: TerminalSharingStore
    let surfaceID: UUID

    init(host: TerminalSizingEngine, store: TerminalSharingStore, surfaceID: UUID) {
        self.host = host
        self.store = store
        self.surfaceID = surfaceID
        publish()
    }

    func publish() {
        store.publish(TerminalSharingSnapshot(state: host.state, selfParticipantID: "mac:1"), surfaceID: surfaceID)
    }

    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool { host.setPolicy(policy); publish(); return true }
    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool { host.setCountsOverride(participantID, value); publish(); return true }
    func sharingDisconnect(participantID: String, by: TerminalDetachActor?) -> Bool {
        disconnected.append(participantID)
        let ok = host.detach(participantID)
        publish()
        return ok
    }
    func sharingNoteSelfActivity() { activity += 1; host.noteActivity("mac:1"); publish() }
    func sharingReattach(asViewer: Bool) -> Bool { reattached.append(asViewer); return true }
}

@MainActor
@Suite struct TerminalSharingStoreTests {
    private func fixture(policy: TerminalSizingPolicy = .latest) -> (TerminalSharingStore, FakeController, UUID) {
        let store = TerminalSharingStore()
        let id = UUID()
        var host = TerminalSizingEngine(
            initialSize: TerminalGridSize(cols: 120, rows: 40),
            policy: policy
        )
        host.attach(TerminalSizingParticipant(id: "mac:1", userID: "u_me", deviceKind: .mac, viewport: TerminalGridSize(cols: 120, rows: 40)))
        host.attach(TerminalSizingParticipant(id: "tui:a", userID: "u_a", deviceKind: .tui, viewport: TerminalGridSize(cols: 50, rows: 30)))
        host.attach(TerminalSizingParticipant(id: "tui:b", userID: "u_b", deviceKind: .tui, viewport: TerminalGridSize(cols: 90, rows: 50)))
        let controller = FakeController(host: host, store: store, surfaceID: id)
        store.register(controller, surfaceID: id)
        return (store, controller, id)
    }

    /// Another attached SSH client can disconnect this Mac's view; its own
    /// local UI must not disconnect itself.
    @Test func onlyAnotherParticipantDisconnectsThisView() {
        let (store, controller, id) = fixture()
        #expect(!store.disconnect(participantID: "mac:1", surfaceID: id))
        let remoteActor = TerminalDetachActor(userID: "u_a", displayName: "A", deviceName: "Remote terminal")
        #expect(store.disconnect(participantID: "mac:1", surfaceID: id, by: remoteActor))
        #expect(controller.disconnected == ["mac:1"])
        #expect(store.snapshot(for: id)?.state.participant("mac:1") == nil)
    }

    @Test func disconnectOthersNeverDisconnectsSelf() {
        let (store, controller, id) = fixture()
        #expect(store.disconnectOthers(surfaceID: id) == 2)
        #expect(Set(controller.disconnected) == ["tui:a", "tui:b"])
        #expect(!store.disconnect(participantID: "mac:1", surfaceID: id))
        #expect(store.snapshot(for: id)?.isShared == false)
    }

    @Test func sizeToMeInSmallestSwitchesToLatestAndTakesTheGrid() {
        let (store, controller, id) = fixture(policy: TerminalSizingPolicy(mode: .smallest))
        #expect(store.snapshot(for: id)?.state.size == TerminalGridSize(cols: 50, rows: 30))
        #expect(store.sizeToMe(surfaceID: id))
        #expect(controller.activity == 1)
        #expect(store.snapshot(for: id)?.state.policy.mode == .latest)
        #expect(store.snapshot(for: id)?.state.size == TerminalGridSize(cols: 120, rows: 40))
    }

    @Test func sizeToMeInPriorityMovesMeToTheTop() {
        let (store, controller, id) = fixture(policy: TerminalSizingPolicy(mode: .priority, priority: ["u_a/tui"]))
        defer { withExtendedLifetime(controller) {} }
        #expect(store.sizeToMe(surfaceID: id))
        #expect(store.snapshot(for: id)?.state.policy.priority == ["u_me/mac", "u_a/tui"])
        #expect(store.snapshot(for: id)?.state.owners == ["mac:1"])
    }

    @Test func sizeToMeClearsMyViewerOverride() {
        let (store, controller, id) = fixture()
        defer { withExtendedLifetime(controller) {} }
        #expect(store.toggleSelfCounts(surfaceID: id))
        #expect(store.snapshot(for: id)?.selfParticipant?.counts == false)
        #expect(store.sizeToMe(surfaceID: id))
        #expect(store.snapshot(for: id)?.selfParticipant?.counts == true)
    }

    @Test func fixedModeWithoutGridFixesTheCurrentGrid() {
        let (store, controller, id) = fixture()
        defer { withExtendedLifetime(controller) {} }
        let size = store.snapshot(for: id)!.state.size
        #expect(store.setMode(.fixed, surfaceID: id))
        #expect(store.snapshot(for: id)?.state.policy.fixed == size)
    }

    @Test func unregisterRemovesSnapshotOnlyForTheOwner() {
        let (store, controller, id) = fixture()
        let other = FakeController(host: controller.host, store: TerminalSharingStore(), surfaceID: id)
        store.unregister(other, surfaceID: id)
        #expect(store.snapshot(for: id) != nil)
        store.unregister(controller, surfaceID: id)
        #expect(store.snapshot(for: id) == nil)
    }
}
