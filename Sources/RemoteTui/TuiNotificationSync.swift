import CmuxSurfaceCatalogModel
import Foundation

/// One machine's notification sync. Owned by that machine's surface provider,
/// which feeds it every accepted state and reports link reconnects. All
/// effects go through the injected closures so tests drive it without a
/// daemon: `deliver` creates the local notification, `send` performs one
/// `notification.ack` round trip over the link.
@MainActor
final class TuiNotificationSync {
    /// A declined row stays undelivered for a later fold; a suppressed row is
    /// consumed and read in the same fold (see `TuiNotificationDeliveryOutcome`).
    typealias Deliverer = @MainActor (TuiNotificationRow, TuiNotificationDeliveryTarget) -> TuiNotificationDeliveryOutcome
    typealias TargetResolver = @MainActor (TuiNotificationRow) -> TuiNotificationDeliveryTarget?
    typealias AckSender = @MainActor (TuiNotificationSyncState.PendingAck) async throws -> Void
    typealias UnreadObserver = @MainActor (Set<String>) -> Void
    /// Withdraw local banners for rows the machine no longer retains.
    typealias Withdrawer = @MainActor ([String]) -> Void

    let machineID: String
    let clientID: String
    private let store: TuiNotificationSyncStore
    private let deliver: Deliverer
    private let resolveTarget: TargetResolver
    private let send: AckSender
    private let unreadChanged: UnreadObserver
    private let withdraw: Withdrawer
    private let newKey: () -> String

    private(set) var state: TuiNotificationSyncState
    private(set) var rows: [TuiNotificationRow] = []
    private(set) var unreadTerminalIDs: Set<String> = []
    private var hasAppliedSnapshot = false
    /// Rows whose delivery was transiently declined or had no local placement.
    /// A catalog change or later feed fold retries only this small set instead
    /// of refolding every unchanged row.
    private var retryableDeliveryIDs: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    /// Set by `retire()`: a replaced sync must not write the shared per-machine
    /// key after its provider is gone.
    private var retired = false

    /// The idempotency key of one `notification.ack` batch.
    nonisolated static func mintAckKey() -> String {
        "mac-ack-\(UUID().uuidString.lowercased())"
    }

    init(
        machineID: String,
        clientID: String,
        store: TuiNotificationSyncStore,
        newKey: @escaping () -> String = TuiNotificationSync.mintAckKey,
        resolveTarget: @escaping TargetResolver,
        deliver: @escaping Deliverer,
        send: @escaping AckSender,
        unreadChanged: @escaping UnreadObserver = { _ in },
        withdraw: @escaping Withdrawer = { _ in }
    ) {
        self.machineID = machineID
        self.clientID = clientID
        self.store = store
        self.newKey = newKey
        self.resolveTarget = resolveTarget
        self.deliver = deliver
        self.send = send
        self.unreadChanged = unreadChanged
        self.withdraw = withdraw
        state = store.load(machineID: machineID)
    }

    /// Fold one accepted state. Called after every installed snapshot or
    /// delta; cheap when the rows did not change.
    @discardableResult
    func apply(rows incoming: [TuiNotificationRow]) -> Bool {
        guard !retired else { return false }
        guard rows != incoming || !retryableDeliveryIDs.isEmpty || !hasAppliedSnapshot else {
            requestFlush()
            return false
        }
        hasAppliedSnapshot = true
        rows = incoming
        let plan = TuiNotificationSyncReducer.plan(rows: incoming, clientID: clientID, state: state)
        var next = plan.state
        var placed: [(TuiNotificationRow, TuiNotificationDeliveryTarget)] = []
        retryableDeliveryIDs.removeAll(keepingCapacity: true)
        for row in plan.deliver {
            if let target = resolveTarget(row) {
                placed.append((row, target))
            } else {
                // Not consumed: the next fold retries placement.
                next.delivered.removeAll { $0 == row.id }
                retryableDeliveryIDs.insert(row.id)
            }
        }
        // Commit before delivering: the store can call back into this sync
        // while a banner is recorded (a focused surface reads it at once), and
        // that re-entrant commit must build on the state that already counts
        // these rows as delivered.
        commit(next)
        if !plan.removed.isEmpty {
            withdraw(plan.removed)
        }
        var undelivered: [String] = []
        var suppressed: [String] = []
        for (row, target) in placed {
            switch deliver(row, target) {
            case .delivered:
                break
            case .declined:
                undelivered.append(row.id)
                retryableDeliveryIDs.insert(row.id)
            case .suppressed:
                suppressed.append(row.id)
            }
        }
        if !undelivered.isEmpty || !suppressed.isEmpty {
            // Built on the current state, not `next`: a delivery can re-enter
            // through the store and commit in between.
            var declined = state
            declined.delivered.removeAll { undelivered.contains($0) }
            if !suppressed.isEmpty {
                declined = TuiNotificationSyncReducer.recordRead(
                    ids: suppressed, rows: rows, clientID: clientID, state: declined, newKey: newKey
                )
            }
            commit(declined)
        }
        requestFlush()
        return true
    }

    /// Local reads of this machine's notifications, by daemon row id.
    func noteRead(notificationIDs: [String]) {
        guard !retired else { return }
        let next = TuiNotificationSyncReducer.recordRead(
            ids: notificationIDs,
            rows: rows,
            clientID: clientID,
            state: state,
            newKey: newKey
        )
        guard next != state else { return }
        commit(next)
        requestFlush()
    }

    /// Local reads by target: every unread row whose current placement the
    /// read covers is acknowledged, whether or not it ever became a local
    /// record (an admission drop, a row placed elsewhere before the terminal
    /// was opened here). Returns the ids so the caller can mirror the read
    /// onto local records that live on another workspace.
    @discardableResult
    func noteRead(coveredBy target: NotificationReadTarget) -> [String] {
        guard !retired else { return [] }
        let pending = state.pendingIDs
        let read = state.readIDs
        var ids: [String] = []
        for row in rows where !row.isRead(by: clientID) && !read.contains(row.id) && !pending.contains(row.id) {
            if case .all = target {
                ids.append(row.id)
            } else if let placement = resolveTarget(row), placement.isCovered(by: target) {
                ids.append(row.id)
            }
        }
        guard !ids.isEmpty else { return [] }
        noteRead(notificationIDs: ids)
        return ids
    }

    /// The link came back. Anything still pending is retried now.
    func linkDidConnect() {
        guard !retired else { return }
        requestFlush()
    }

    /// Attempts outstanding reads and joins that pass, including persistence.
    /// Failed sends remain pending for the next reconnect or accepted state.
    func flushPendingReads() async {
        requestFlush()
        while let flushTask { await flushTask.value }
        await store.flush()
    }

    /// Stop writing on behalf of this machine. A replacement sync for the same
    /// machine loads the durable state itself; this one must not overwrite
    /// it from an in-flight flush.
    func retire() {
        retired = true
        flushTask?.cancel()
        flushTask = nil
    }

    func forget() {
        retire()
        store.remove(machineID: machineID)
    }

    private func commit(_ next: TuiNotificationSyncState) {
        guard !retired else { return }
        if next != state {
            state = next
            store.save(next, machineID: machineID)
        }
        let unread = TuiNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: clientID, state: next)
        if unread != unreadTerminalIDs {
            unreadTerminalIDs = unread
            unreadChanged(unread)
        }
    }

    /// One in-flight flush at a time, oldest batch first. A failed send stops
    /// the pass and leaves the batch for the next accepted state or reconnect;
    /// there is no timer and no backoff here because the link owns recovery.
    private func requestFlush() {
        guard !retired, !state.pendingAcks.isEmpty else { return }
        if flushTask != nil {
            flushRequested = true
            return
        }
        flushTask = Task { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        defer {
            flushTask = nil
            if flushRequested {
                flushRequested = false
                requestFlush()
            }
        }
        while let batch = state.pendingAcks.first {
            if Task.isCancelled { return }
            do {
                await store.flush()
                guard !retired, !Task.isCancelled else { return }
                try await send(batch)
            } catch {
                return
            }
            if retired { return }
            rows = TuiNotificationSyncReducer.markingRead(ids: batch.ids, clientID: clientID, rows: rows)
            commit(TuiNotificationSyncReducer.ackCompleted(key: batch.key, state: state))
        }
    }
}
