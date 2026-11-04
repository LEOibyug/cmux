import CmuxRemoteSession
import CmuxFoundation
import Combine
import Foundation

extension Notification.Name {
    /// Posted on the main actor after a machine's unread terminal set changes.
    static let cmuxTuiNotificationUnreadDidChange = Notification.Name("cmux.sshNotifications.unreadDidChange")
}

/// App-wide registry of per-machine syncs. Owns the one subscription on the
/// notification store that turns local reads into acknowledgements, and the
/// unread index the remote catalog renders.
@MainActor
final class TuiNotificationSyncHub {
    let persistenceStore: TuiNotificationSyncStore
    private var syncs: [String: TuiNotificationSync] = [:]
    private var notificationGate: TuiNotificationGate

    /// Defaults resolve here rather than as default arguments: the store is
    /// main-actor isolated and cannot be constructed in a default-argument
    /// context.
    init(
        persistenceStore: TuiNotificationSyncStore? = nil,
        gate: TuiNotificationGate = TuiNotificationGate()
    ) {
        self.persistenceStore = persistenceStore ?? TuiNotificationSyncStore()
        notificationGate = gate
    }

    /// One admission budget across all live machine providers.
    func admit(_ row: TuiNotificationRow, machineID: String) -> TuiNotificationGate.Decision {
        notificationGate.admit(machineID: machineID, event: TuiNotificationEvent(
            id: row.id, terminalID: row.terminalID, title: row.title, body: row.body
        ))
    }
    private(set) var unreadTerminalIDs: [String: Set<String>] = [:]
    private var storeSubscription: AnyCancellable?
    private weak var store: TerminalNotificationStore?
    private var unreadRemoteKeys: Set<String>?

    func register(_ sync: TuiNotificationSync) {
        syncs[sync.machineID] = sync
        observeStoreIfNeeded()
    }

    func unregister(machineID: String) {
        syncs.removeValue(forKey: machineID)
        if unreadTerminalIDs.removeValue(forKey: machineID) != nil {
            NotificationCenter.default.post(name: .cmuxTuiNotificationUnreadDidChange, object: nil)
        }
    }

    func sync(machineID: String) -> TuiNotificationSync? {
        syncs[machineID]
    }

    func setUnread(_ terminalIDs: Set<String>, machineID: String) {
        if terminalIDs.isEmpty {
            guard unreadTerminalIDs.removeValue(forKey: machineID) != nil else { return }
        } else {
            guard unreadTerminalIDs[machineID] != terminalIDs else { return }
            unreadTerminalIDs[machineID] = terminalIDs
        }
        #if DEBUG
        cmuxDebugLog("SSH.notifications.unread machine=\(machineID) terminals=\(terminalIDs.count)")
        #endif
        NotificationCenter.default.post(name: .cmuxTuiNotificationUnreadDidChange, object: nil)
    }

    /// Correlation keys of SSH notifications that were unread in `previous`
    /// and are read or gone in `current`. A dismissal counts as a read: the
    /// person chose not to see it again, on this Mac and on the machine.
    static func newlyReadKeys(previous: Set<String>, current: [TerminalNotification]) -> (read: Set<String>, unread: Set<String>) {
        var unread = Set<String>()
        for notification in current where !notification.isRead {
            if let key = notification.correlationKey, key.hasPrefix(TuiNotificationCorrelation.prefix) {
                unread.insert(key)
            }
        }
        return (previous.subtracting(unread), unread)
    }

    private func observeStoreIfNeeded() {
        guard store == nil, let store = AppDelegate.shared?.notificationStore else { return }
        attach(store: store)
    }

    /// Binds the hub to the local store. Local records that become read or
    /// are dismissed acknowledge their rows, and every read or clear the
    /// store applies by target is mirrored onto the rows placed there.
    func attach(store: TerminalNotificationStore) {
        guard self.store !== store else { return }
        self.store = store
        unreadRemoteKeys = nil
        storeSubscription = store.$notifications
            .receive(on: RunLoop.main)
            .sink { [weak self] notifications in
                MainActor.assumeIsolated {
                    self?.storeDidChange(notifications)
                }
            }
        store.readTargetObserver = { [weak self] target in
            self?.noteRead(coveredBy: target)
        }
        store.readNotificationObserver = { [weak self] notifications in
            self?.noteRead(notifications: notifications)
        }
    }

    /// A read the store applied by target (a focused pane, a visited
    /// workspace, mark-all-read, `cmux notify --clear`). Every machine
    /// acknowledges the rows whose current placement the read covers, so the
    /// remote catalog dot follows the dismissal even for rows that never became a
    /// local record; records for those rows that live on another workspace
    /// (placed there before the terminal was opened here) are read with them.
    func noteRead(coveredBy target: NotificationReadTarget) {
        var readByMachine: [String: Set<String>] = [:]
        for sync in syncs.values {
            let ids = sync.noteRead(coveredBy: target)
            if !ids.isEmpty { readByMachine[sync.machineID] = Set(ids) }
        }
        guard !readByMachine.isEmpty, let store else { return }
        let ids = store.notifications.compactMap { notification -> UUID? in
            guard !notification.isRead, let key = notification.correlationKey,
                  let source = TuiNotificationCorrelation.parse(key),
                  readByMachine[source.machineID]?.contains(source.notificationID) == true else { return nil }
            return notification.id
        }
        guard !ids.isEmpty else { return }
        store.markNotificationFeedRead(ids: Set(ids))
    }

    func storeDidChange(_ notifications: [TerminalNotification]) {
        guard let previous = unreadRemoteKeys else {
            // First observation seeds the baseline. Rows restored from the
            // durable feed history as already-read never become acks here;
            // the daemon already has them or they were read elsewhere.
            unreadRemoteKeys = Self.newlyReadKeys(previous: [], current: notifications).unread
            return
        }
        let (read, unread) = Self.newlyReadKeys(previous: previous, current: notifications)
        unreadRemoteKeys = unread
        guard !read.isEmpty else { return }
        var byMachine: [String: [String]] = [:]
        for key in read {
            guard let parsed = TuiNotificationCorrelation.parse(key) else { continue }
            byMachine[parsed.machineID, default: []].append(parsed.notificationID)
        }
        for (machineID, ids) in byMachine {
            noteRead(notificationIDs: ids, machineID: machineID)
        }
    }

    /// Reads by daemon row id. Without a live sync for the machine (asleep,
    /// feature-suspended, between providers) the read is written to the
    /// durable state directly, so the replacement sync loads it as a pending
    /// acknowledgement instead of restoring the row as unread.
    func noteRead(notificationIDs ids: [String], machineID: String) {
        if let sync = syncs[machineID] {
            sync.noteRead(notificationIDs: ids)
            return
        }
        let state = persistenceStore.load(machineID: machineID)
        // No rows are known here, so the client id (only consulted against a
        // row's `read_by`) does not take part in the decision.
        let next = TuiNotificationSyncReducer.recordRead(
            ids: ids, rows: [], clientID: "", state: state, newKey: TuiNotificationSync.mintAckKey
        )
        guard next != state else { return }
        persistenceStore.save(next, machineID: machineID)
    }

    /// An exact feed-record read has already changed the local sidebar. Fold
    /// its SSH correlation keys before the store publisher's next delivery,
    /// so both sidebar projections change in the same turn.
    func noteRead(notifications: [TerminalNotification]) {
        var byMachine: [String: [String]] = [:]
        for notification in notifications {
            guard let key = notification.correlationKey,
                  let source = TuiNotificationCorrelation.parse(key) else { continue }
            byMachine[source.machineID, default: []].append(source.notificationID)
        }
        for (machineID, ids) in byMachine {
            noteRead(notificationIDs: ids, machineID: machineID)
        }
    }
}
