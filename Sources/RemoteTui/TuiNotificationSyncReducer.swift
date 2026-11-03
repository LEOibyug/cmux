import CmuxSurfaceCatalogModel
import Foundation

/// Pure transitions over `TuiNotificationSyncState`. Every effect the sync
/// performs is decided here and only here, so the fault-injection tests cover
/// the same code the app runs.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
enum TuiNotificationSyncReducer: Sendable {
    struct Plan: Equatable, Sendable {
        var deliver: [TuiNotificationRow]
        /// Ids this Mac delivered that the daemon no longer retains, whether a
        /// `notification.clear` removed them or the ledger evicted them. The
        /// local banner is withdrawn in both cases: the machine is the source
        /// of truth and it no longer has the row.
        var removed: [String]
        var state: TuiNotificationSyncState

        init(
            deliver: [TuiNotificationRow],
            removed: [String],
            state: TuiNotificationSyncState
        ) {
            self.deliver = deliver
            self.removed = removed
            self.state = state
        }
    }

    /// Fold one accepted set of rows. A row is delivered when this client has
    /// not read it, has not delivered it, and is not already acknowledging it.
    /// Bookkeeping for rows the ledger evicted is dropped in the same step.
    static func plan(
        rows: [TuiNotificationRow],
        clientID: String,
        state: TuiNotificationSyncState
    ) -> Plan {
        let retained = Set(rows.map(\.id))
        var next = state
        let removed = next.delivered.filter { !retained.contains($0) }
        next.delivered.removeAll { !retained.contains($0) }
        // Pending acks are never pruned here: the daemon answers an evicted
        // id with `unknown`, which completes the batch, and dropping a batch
        // locally would lose a read that was recorded before the rows arrived.
        let delivered = Set(next.delivered)
        let pending = next.pendingIDs
        var read = next.readIDs
        var deliver: [TuiNotificationRow] = []
        for row in rows {
            if row.isRead(by: clientID) {
                appendReadID(row.id, to: &next, ids: &read)
                continue
            }
            guard !read.contains(row.id),
                  !delivered.contains(row.id),
                  !pending.contains(row.id) else { continue }
            deliver.append(row)
            next.delivered.append(row.id)
        }
        if next.delivered.count > TuiNotificationSyncState.deliveredLimit {
            next.delivered.removeFirst(next.delivered.count - TuiNotificationSyncState.deliveredLimit)
        }
        return Plan(deliver: deliver, removed: removed, state: next)
    }

    /// Record local reads. Ids already pending, or whose row is known to be
    /// read by this client, are skipped; every other id forms a new batch,
    /// including ids whose rows have not arrived yet (a read after launch
    /// before the first snapshot). The daemon reports ids it no longer
    /// retains as `unknown`, which completes the batch. The batch key is
    /// minted once and survives retries.
    static func recordRead(
        ids: [String],
        rows: [TuiNotificationRow],
        clientID: String,
        state: TuiNotificationSyncState,
        newKey: () -> String
    ) -> TuiNotificationSyncState {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = state.pendingIDs
        let read = state.readIDs
        var batch: [String] = []
        for id in ids where !batch.contains(id) {
            if pending.contains(id) { continue }
            if read.contains(id) { continue }
            if let row = byID[id], row.isRead(by: clientID) { continue }
            batch.append(id)
        }
        guard !batch.isEmpty else { return state }
        var next = state
        next.pendingAcks.append(TuiNotificationSyncState.PendingAck(key: newKey(), ids: batch))
        return next
    }

    static func ackCompleted(key: String, state: TuiNotificationSyncState) -> TuiNotificationSyncState {
        var next = state
        var acknowledged: [String] = []
        var remaining: [TuiNotificationSyncState.PendingAck] = []
        for batch in next.pendingAcks {
            if batch.key == key {
                acknowledged.append(contentsOf: batch.ids)
            } else {
                remaining.append(batch)
            }
        }
        guard !acknowledged.isEmpty else { return state }
        next.pendingAcks = remaining
        var read = next.readIDs
        for id in acknowledged {
            appendReadID(id, to: &next, ids: &read)
        }
        return next
    }

    private static func appendReadID(
        _ id: String,
        to state: inout TuiNotificationSyncState,
        ids: inout Set<String>
    ) {
        guard ids.insert(id).inserted else { return }
        if state.read.count >= TuiNotificationSyncState.deliveredLimit,
           let evicted = state.read.first {
            state.read.removeFirst()
            ids.remove(evicted)
        }
        state.read.append(id)
    }

    /// Read-your-write overlay: after the daemon confirmed a batch, the rows
    /// it named carry this client until the feed delivers the same fact, so
    /// the unread set cannot flicker back between the ack and its delta.
    static func markingRead(
        ids: [String],
        clientID: String,
        rows: [TuiNotificationRow]
    ) -> [TuiNotificationRow] {
        let acked = Set(ids)
        return rows.map { row in
            guard acked.contains(row.id), !row.readBy.contains(clientID) else { return row }
            var row = row
            row.readBy.append(clientID)
            row.readBy.sort()
            return row
        }
    }

    /// Terminals with a notification this client has neither read nor
    /// acknowledged, for the remote catalog's attention dot.
    static func unreadTerminalIDs(
        rows: [TuiNotificationRow],
        clientID: String,
        state: TuiNotificationSyncState
    ) -> Set<String> {
        let pending = state.pendingIDs
        let read = state.readIDs
        var result = Set<String>()
        for row in rows where !row.isRead(by: clientID)
            && !read.contains(row.id)
            && !pending.contains(row.id) {
            if let terminalID = row.terminalID { result.insert(terminalID) }
        }
        return result
    }
}
