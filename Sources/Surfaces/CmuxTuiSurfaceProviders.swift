import CmuxSSHClipboardTrust
import CmuxRemoteSession
import CmuxTui
import CmuxCore
import CmuxFoundation
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
/// One SSH host's cmux-tui terminals, browser tabs, and forwarded ports.
@MainActor
final class CmuxTuiSurfaceProvider: SurfaceProvider {
    let machineID: String
    var machine: SurfaceMachineID { summary.machine }
    private(set) var info: SurfaceMachineInfo
    var summary: RemoteTuiMachine
    /// Opens URLs requested by the connected SSH host in the local browser.
    var guestURLService: TuiGuestURLService?
    var guestURLProjectionVersion: UInt64?
    var guestURLTerminalIDs: [String] = []
    /// A local placement (a pane opening, a workspace binding) is a catalog
    /// change, not a daemon state; it re-runs the fold so rows that had no
    /// local target get delivered.
    /// The agent sessions this machine's roster last replayed into the local
    /// hook queue, so repeated snapshots do not replay the same session.
    var agentHookMirror = TuiAgentHookMirror()
    var notificationSync: TuiNotificationSync?
    var notificationPlacementObserver: NSObjectProtocol?
    let links: any RemoteTuiLinkManaging
    unowned let catalog: SurfaceCatalog
    let sshClipboardWriteTrustStore: SSHClipboardWriteTrustStore
    /// Loopback browser forwards shared by this host's projections.
    let portAccessStore: RemotePortAccessStore
    let browserPolicy: @MainActor () -> BrowserURLAllowlistPolicy
    /// Invalidates suspended work when this provider is stopped or replaced.
    var isRetired = false
    private(set) var lifecycleGeneration: UInt64 = 0
    /// Invalidates an older refresh before it can publish over a newer one.
    var refreshGeneration: UInt64 = 0
    let refreshCoordinator = TuiProviderRefreshCoordinator()
    let terminalMutationQueue = TuiTerminalMutationQueue()
    /// The only installed daemon graph for this machine. The catalog receives the
    /// same immutable value with its derived rows in one transaction.
    private(set) var tuiState: TuiState?
    /// Local ordering fence for concurrent snapshot commands and the event
    /// reader. Remote generations are opaque, so a response from an older
    /// request must not replace a generation installed later in the same turn.
    private var tuiStateInstallVersion: UInt64 = 0
    /// Generations accepted by this provider instance. Generation identifiers
    /// are opaque, but a repeated identifier after a reconnect is still proof
    /// that a response came from an older link. Keeping this set prevents a
    /// delayed old snapshot from time-travelling the canonical graph.
    private var acceptedTuiGenerations: Set<String> = []
    /// A failed event feed is a transport warning, separate from the freshness of the last
    /// accepted snapshot. Agents can read the exact graph and the warning in one export.
    private var eventsFeedWarning: String?
    private var stateRecoveryRefreshTask: Task<Void, Never>?
    private var stateRecoveryRefreshQueued = false
    private var stateRecoveryCount = 0
    /// The cursor of the last full snapshot that disagreed with the installed
    /// graph at the same cursor. The first conflict schedules a recovery read;
    /// a second full snapshot conflicting at this cursor is adopted.
    private(set) var equalCursorConflict: TuiCursor?
    /// Set only by the install that armed ``equalCursorConflict``, so a read
    /// that cannot adopt (stale, or fenced by a pending rename) at an already
    /// armed cursor does not spend another recovery read.
    private(set) var equalCursorConflictArmedByLastInstall = false
    private static let stateRecoveryLimit = 5
    private var changeWatcher: Task<Void, Never>?
    /// Identity of the link owned by `changeWatcher`. A provider can replace a
    /// dead link during refresh; the old stream must not clear or restart the
    /// watcher for the new link.
    private var watchedLink: RemoteMachineLink?
    private var changeWatcherID: UUID?
    private var scheduledRefresh: Task<Void, Never>?
    private var scheduledRefreshForce = false
    private var portsCache: (ports: [Int], at: Date)?
    var portDiscovery = TuiPortDiscovery()
    private(set) var summaryGeneration: UInt64 = 0
    func publishPortDiscovery() {
        guard isRegisteredInCatalog() else { return }
        info.portDiscoveryState = portDiscovery.state
        catalog.updateMachine(info, from: self)
    }
    @discardableResult
    func requestPortDiscovery() -> UInt64 {
        let request = portDiscovery.request()
        publishPortDiscovery()
        return request
    }
    func abandonPortDiscoveryRequest(_ request: UInt64) {
        let previousState = portDiscovery.state
        portDiscovery.abandonRequest(request)
        if portDiscovery.state != previousState { publishPortDiscovery() }
    }
    /// Panels this provider created (or replaced) in this process. A projection whose
    /// panel is not here came back from a restored session as a placeholder shell.
    var materializedPanels: Set<UUID> = []
    /// Setup belongs to the local projection and is cancelled when that pane ends.
    var browserPaneTasks: [UUID: Task<Void, Never>] = [:]
    /// Native cloud terminals own a manual attachment separate from their
    /// catalog projection. The provider retains it for the life of the pane.
    var manualMirrorSessions: [UUID: TuiManualMirrorSession] = [:]
    /// Attach loops of reserved panes (restored, or a workspace opened as a whole), by panel id.
    var restoredAttachTasks: [UUID: Task<Void, Never>] = [:]
    /// Numeric cmux-tui surface ids are process-local. Re-read the legacy tree
    /// when the link socket generation changes or an attachment disconnects,
    /// then reuse the result for the rest of that socket generation.
    var manualMirrorSurfaceIDsSocketPath: String?
    /// Arms the next attachment pass after one that could not resolve every
    /// open pane; reset by a fully resolved pass.
    let attachmentRetry = TuiTerminalAttachmentRetryScheduler()
    let attachmentLog = TuiTerminalAttachmentLog()
    /// Drives the bounded backoff between resolver attempts of one open.
    let attachmentClock: any Clock<Duration>
    /// Terminal → tab from the last snapshot, so an exited terminal (whose own selector
    /// no longer resolves in cmux-tui) can still be closed through its tab.
    var tabByTerminal: [String: String] = [:]
    /// Coalesces concurrent first opens of a zero-view terminal. `terminal.project` is a
    /// mutation, so two local panes racing on the same pool row must share one remote view.
    // Internal so the manual-mirror extension can share the provider-owned task map.
    var remoteTerminalProjectionTasks: [String: Task<SurfaceRemotePlacement, Error>] = [:]
    /// User labels from the last authoritative snapshot, used to compensate a
    /// multi-view rename if a later tab mutation fails.
    private var tabNameByID: [String: String] = [:]
    /// A mutation response is a read-your-write receipt, but the event stream or
    /// the next snapshot can lag it. Keep the exact created row and placement
    /// until an accepted graph reaches that receipt. This is a transient view
    /// overlay, never a second remote-state store.
    var pendingRemoteCreations: [SurfaceResourceID: PendingRemoteCreation] = [:]
    /// Rename receipts are transient read-your-write fences. They are keyed by
    /// daemon identity, not by a local title or projection, because one remote
    /// tab can be shown in several windows. The canonical graph remains the
    /// only source of remote values.
    enum PendingRemoteRenameKey: Hashable {
        case workspace(String)
        case tab(String)
    }
    struct PendingRemoteRename {
        var name: String
        var receipt: TuiCursor
    }
    var pendingRemoteRenames: [PendingRemoteRenameKey: PendingRemoteRename] = [:]
    init(
        summary: RemoteTuiMachine,
        links: any RemoteTuiLinkManaging,
        catalog: SurfaceCatalog,
        sshClipboardWriteTrustStore: SSHClipboardWriteTrustStore? = nil,
        attachmentClock: any Clock<Duration> = ContinuousClock(),
        portAccessStore: RemotePortAccessStore? = nil,
        browserPolicy: @escaping @MainActor () -> BrowserURLAllowlistPolicy = { BrowserURLAllowlistPolicy() }
    ) {
        machineID = summary.id
        self.attachmentClock = attachmentClock
        self.summary = summary
        self.links = links
        self.catalog = catalog
        self.sshClipboardWriteTrustStore = sshClipboardWriteTrustStore ?? SSHClipboardWriteTrustStore(defaults: .standard)
        self.portAccessStore = portAccessStore ?? RemotePortAccessStore()
        self.browserPolicy = browserPolicy
        portDiscovery.reconcile(supportsPreviews: true,
                                privateAddress: summary.preferredPrivateAddress, allowLoopback: true)
        info = Self.info(from: summary, linkState: .connecting, linkError: nil,
                         portDiscoveryState: portDiscovery.state)
    }
    /// Stops machine-bound activity while retaining this provider and its graph.
    /// The control plane may report the machine running again later.
    func stopTransportResources() {
        stopSharedTransportResources()
        portDiscovery.invalidate()
    }
    private func stopSharedTransportResources() {
        lifecycleGeneration &+= 1
        guestURLService?.stop()
        guestURLService = nil
        refreshCoordinator.cancel()
        changeWatcher?.cancel()
        changeWatcher = nil
        watchedLink = nil
        changeWatcherID = nil
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        scheduledRefreshForce = false
        stateRecoveryRefreshTask?.cancel()
        stateRecoveryRefreshTask = nil
        stateRecoveryRefreshQueued = false
        for task in remoteTerminalProjectionTasks.values { task.cancel() }
        remoteTerminalProjectionTasks.removeAll()
    }
    /// Retires every attachment and transport task this provider owns.
    ///
    /// - Parameter stopReason: What open panes present afterwards. Panes stay
    ///   open; each keeps a card for this reason instead of a frozen frame.
    func retireTransport(stopReason: TuiManualMirrorStopReason = .tuiUnavailable) {
        isRetired = true
        notificationSync?.retire()
        if catalog.tuiNotificationSyncHub.sync(machineID: machineID) === notificationSync {
            catalog.tuiNotificationSyncHub.unregister(machineID: machineID)
        }
        notificationSync = nil
        if let notificationPlacementObserver {
            NotificationCenter.default.removeObserver(notificationPlacementObserver)
            self.notificationPlacementObserver = nil
        }
        // The first read after resuming must arm afresh, never adopt at once.
        equalCursorConflict = nil
        stopSharedTransportResources()
        portDiscovery.invalidate()
        terminalMutationQueue.cancelAll()
        for task in browserPaneTasks.values { task.cancel() }
        browserPaneTasks.removeAll()
        refreshGeneration &+= 1
        stateRecoveryCount = 0
        eventsFeedWarning = nil
        for session in manualMirrorSessions.values { session.stop(reason: stopReason) }
        manualMirrorSessions.removeAll()
        manualMirrorSurfaceIDsSocketPath = nil
        attachmentRetry.cancel()
        pendingRemoteCreations.removeAll()
        pendingRemoteRenames.removeAll()
        acceptedTuiGenerations.removeAll(); catalog.notifyChange(for: machine)
    }
    /// Publishes a link state the provider decided outside a refresh pass.
    func publishLinkStatus(_ state: SurfaceLinkState, error: String?) {
        info.linkState = state
        info.linkError = error
        catalog.updateMachine(info, from: self)
    }
    /// One refresh pass. Sleeping machines retain their graph without being woken.
    func performRefresh(force: Bool) async -> Bool {
        let lifecycle = lifecycleGeneration
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else { return false }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        let machine = self.machine
        let requestVersion = tuiStateInstallVersion
        let previousResources = catalog.authoritativeSnapshot.resources(on: machine)
        let preservedNonPortResources = previousResources.filter { !$0.id.isForwardedPort }
        let privateAddress = summary.preferredPrivateAddress
        portDiscovery.reconcile(
            supportsPreviews: supportsPortPreviews,
            privateAddress: privateAddress,
            allowLoopback: machine.isSSH
        )
        var scannedPorts: [Int]?
        if !supportsPortPreviews {
            scannedPorts = []
        } else if !portDiscovery.mayScan {
            scannedPorts = portsCache?.ports
        } else {
            // Keep the last private-link scan while this refresh reconnects. A new
            // scan runs through cmux-tui after the link is ready. Routine catalog
            // refresh must never use provider exec or the web control plane.
            scannedPorts = portsCache?.ports
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        // A decoded snapshot is not automatically an authorization boundary. It
        // can lose an install race, or be older than the graph already accepted.
        // Callers must use only a graph established by this refresh as mutation
        // evidence, never the retained stale graph.
        var snapshotEstablishedCurrentGraph = false
        var portScan: Task<[Int]?, Never>?
        // Stats and the port scan never gate this pass: joined readers (a
        // New Machine open's `ensure_linked`) wait for the pass, not for them.
        // They are cancelled only when the pass ends before handing them off.
        var handedOffFollowUps = false
        defer {
            if !handedOffFollowUps {
                portScan?.cancel()
            }
        }
        do {
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            let connected = try await links.connected(machineID: machineID)
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            // The port scan and graph snapshot use independent daemon requests.
            // Start both after the link is ready. The graph publishes as soon as
            // the snapshot lands; ports publish when their scan finishes. The
            // scan runs a guest command and took most of a second on a machine
            // that had just resumed, which held New Machine's first terminal
            // back for nothing (it only feeds port-preview rows).
            portScan = Task { [weak self] in
                await self?.ports(link: link, socketPath: connected.socketPath, force: force, lifecycle: lifecycle, privateAddress: privateAddress)
            }
            async let snapshotData = link.run(arguments: TuiRequests.snapshotArguments(socketPath: connected.socketPath))
            watchChanges(link: link, generation: lifecycle)
            configureGuestURLOpen(link: link, socketPath: connected.socketPath)
            let data = try await snapshotData
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let incoming = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine)
            else { throw ProviderError.invalidSnapshot(machineID) }
            let installed = installSnapshotIfNewer(incoming, requestVersion: requestVersion)
            // A first equal-cursor conflict keeps the graph; read again so a
            // repeated conflict can adopt the daemon's answer. When the budget
            // is spent the conflict stays armed, and the next refresh adopts.
            if !installed, equalCursorConflictArmedByLastInstall {
                scheduleStateRecoveryRefresh()
            }
            // Equal cursors are a valid no-op refresh only when the revisioned
            // graph is equivalent. A cursor alone is not proof
            // that a malformed or misconfigured daemon returned the same graph.
            // A newer event can also win the race while this snapshot is in
            // flight; the final install-version check below covers that case.
            snapshotEstablishedCurrentGraph = installed
            // Derive compatibility maps from the graph that won the install race.
            // The event reader may have advanced it while this snapshot was in flight.
            let authoritative = tuiState?.snapshotObject() ?? object
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: authoritative)
            tabNameByID = CmuxTuiSnapshotParser.tabNames(fromSnapshot: authoritative)
            if let cursor = tuiState?.cursor {
                await link.setEventsCursor(cursor)
                // This is deliberately adjacent to the mode check. A legacy
                // snapshot suspends the reader; the first accepted versioned
                // snapshot must reopen it on the same refresh, not wait for a
                // later reconnect or optional lookup.
                let subscriptionResumed = await link.resumeEventsSubscription(from: cursor)
                if TuiEventFeedRecoveryDecision.shouldClearWarning(
                    snapshotCursor: cursor,
                    subscriptionResumed: subscriptionResumed
                ) {
                    eventsFeedWarning = nil
                }
            } else {
                // Keep legacy VMs readable, but do not consume an event stream
                // whose items cannot be ordered against the installed snapshot.
                await link.suspendEventsSubscription()
            }
            guard await reconcileManualMirrorAttachments(
                connected: connected, link: link, lifecycle: lifecycle, refresh: generation
            ) else { return false }
        } catch {
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            portDiscovery.linkFailed()
            let status = await links.status(machineID: machineID)
            linkState = eventsFeedWarning == nil ? (status?.state ?? .error) : .error
            let text = eventsFeedWarning ?? status?.error ?? RemoteMachineLink.errorText(error)
            linkError = text
            #if DEBUG
            cmuxDebugLog("cloud.provider.refreshFailed machine=\(machineID) state=\(linkState) error=\(String(reflecting: error))")
            #endif
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        // An earlier pass's rescan can land during this snapshot read; publish the inventory it accepted.
        let currentPorts = supportsPortPreviews ? portsCache?.ports ?? [] : []
        if let eventsFeedWarning {
            linkState = .error
            linkError = eventsFeedWarning
        }
        let remoteWorkspaces = tuiState.map(Self.remoteWorkspaces)
        // Publish the graph without waiting for stats. Stats is a control-plane
        // HTTP read (provider status plus a guest exec, ~0.8 s) that only fills
        // the CPU/memory/disk gauges; awaiting it here held a new machine's
        // first terminal back by that long after the link was already up.
        // Keep the last gauges until the new read lands below.
        info = Self.info(
            from: summary,
            linkState: linkState,
            linkError: linkError,
            remoteWorkspaces: remoteWorkspaces,
            portDiscoveryState: portDiscovery.state
        ).carryingGauges(from: info)
        if let tuiState {
            // A successful read or an event install proves the retained graph is
            // current. A failed or stale read keeps the graph for diagnosis but
            // marks it stale, so agents can see it without treating it as truth.
            let stateAdvancedDuringRead = tuiStateInstallVersion != requestVersion
            snapshotEstablishedCurrentGraph = snapshotEstablishedCurrentGraph || stateAdvancedDuringRead
            // A successful snapshot is current even when the subscription is degraded. The
            // warning stays in machine info, so agents see both the exact last read and the
            // missing live-feed guarantee instead of an apparently permanent stale graph.
            let observation: TuiStateObservation = snapshotEstablishedCurrentGraph
                ? .current
                : .stale(reason: eventsFeedWarning ?? info.linkError ?? info.linkState.rawValue)
            publish(
                tuiState,
                ports: currentPorts,
                reconcileTitles: snapshotEstablishedCurrentGraph,
                observation: observation
            )
        } else {
            let resources = resourcesWithPendingCreations([], state: nil)
            var fallback = resources
            if scannedPorts == nil {
                appendMissingResources(preservedNonPortResources, to: &fallback)
            }
            let accepted = catalog.replaceResources(
                catalog.preservingConcurrentPortResources(fallback, on: machine, since: previousResources),
                on: machine,
                info: info,
                from: self
            )
            guard accepted else { return false }
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        reprojectRestoredPanes(generation: lifecycle)
        handedOffFollowUps = true
        let publishedPorts = currentPorts
        let observation: TuiStateObservation = snapshotEstablishedCurrentGraph
            ? .current
            : .stale(reason: info.linkError ?? info.linkState.rawValue)
        Task { [weak self, portScan] in
            // The scan's request fence already decided whether its inventory is current, so a
            // summary poll or cached pass that retired this refresh cannot strand the settled
            // status over the previous rows. The graph's freshness is whatever the catalog holds now.
            if let portScan, let refreshedPorts = await portScan.value,
               let self, self.isCurrentLifecycleGeneration(lifecycle),
               self.portDiscovery.scan?.ports == refreshedPorts,
               refreshedPorts != publishedPorts, let tuiState = self.tuiState {
                let current = self.catalog.tuiStateObservations[self.machine] ?? observation
                self.publish(tuiState, ports: refreshedPorts, reconcileTitles: false, observation: current)
                // The graph snapshot intentionally publishes before the guest
                // port scan. A restored browser whose port was absent from the
                // first publication must be reprojected when that inventory
                // becomes authoritative, otherwise it remains on the stale
                // unavailable card forever.
                self.reprojectRestoredPanes(generation: lifecycle)
            }
        }
        return snapshotEstablishedCurrentGraph
    }
    /// A full snapshot read at the installed cursor disagrees with the graph the
    /// deltas built. One of them is wrong, and nothing later at this cursor
    /// can reconcile them, so refusing forever would wedge the machine.
    ///
    /// The first conflict keeps the installed graph and arms a recovery read
    /// (the caller schedules it), so a single race cannot discard state. A
    /// second full snapshot conflicting at the same cursor wins: a full read
    /// at the current cursor is the daemon's own answer. Adoption replaces the
    /// whole graph, exactly like any fresh install, so a field or key the
    /// daemon does not send is absent afterwards rather than kept from the
    /// delta-built graph. App-side overlays (pending renames, pending
    /// creations) live outside `tuiState` and are reapplied on publish.
    /// Event-feed snapshots and reads that started before a newer install
    /// never count: only a current full refresh can arm or adopt.
    private func resolveEqualCursorConflict(incoming: TuiState, requestVersion: UInt64?) -> Bool {
        guard let requestVersion, requestVersion == tuiStateInstallVersion, let cursor = incoming.cursor else {
            #if DEBUG
            cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=equal-cursor-conflict")
            #endif
            return false
        }
        guard equalCursorConflict == cursor else {
            equalCursorConflict = cursor
            equalCursorConflictArmedByLastInstall = true
            #if DEBUG
            cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=equal-cursor-conflict armed=1")
            #endif
            return false
        }
        tuiState = incoming
        tuiStateInstallVersion &+= 1
        equalCursorConflict = nil
        // The recovery read that armed this succeeded; it must not count
        // against the budget later event-feed barriers rely on.
        stateRecoveryCount = 0
        retirePendingRemoteRenames(observed: incoming)
        return true
    }

    @discardableResult
    func installSnapshotIfNewer(_ incoming: TuiState, requestVersion: UInt64? = nil) -> Bool {
        equalCursorConflictArmedByLastInstall = false
        guard acceptsIncomingGeneration(incoming.cursor) else {
            #if DEBUG
            cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=old-generation")
            #endif
            return false
        }
        // A snapshot with the exact installed cursor is a valid no-op only when
        // its revisioned graph and every pending receipt agree. This is important after a
        // rename: a delayed equal-cursor predecessor must not look current.
        // Two missing cursors (a legacy daemon) carry no ordering at all, so
        // they are not equal; the snapshot decision below handles them.
        if let current = tuiState, let currentCursor = current.cursor, currentCursor == incoming.cursor {
            guard current.hasSameRevisionedContent(as: incoming), incomingPassesPendingRenameFence(incoming) else {
                // A pending rename's predecessor is refused outright; only a
                // content conflict can arm recovery.
                if incomingPassesPendingRenameFence(incoming), !current.hasSameRevisionedContent(as: incoming) {
                    return resolveEqualCursorConflict(incoming: incoming, requestVersion: requestVersion)
                }
                #if DEBUG
                cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=equal-cursor-conflict")
                #endif
                return false
            }
            guard requestVersion == nil || requestVersion == tuiStateInstallVersion || incoming == current else {
                return false
            }
            tuiState = incoming
            tuiStateInstallVersion &+= 1
            equalCursorConflict = nil
            retirePendingRemoteRenames(observed: incoming)
            return true
        }
        switch TuiStateSyncDecision.forSnapshot(
            incoming: incoming.cursor,
            current: tuiState?.cursor
        ) {
        case .ignoreStale:
            return false
        case .installSnapshot:
            if let current = tuiState,
               let currentCursor = current.cursor,
               let incomingCursor = incoming.cursor,
               currentCursor.generation != incomingCursor.generation,
               let requestVersion,
                requestVersion != tuiStateInstallVersion {
                return false
            }
            // Without cursors only the install version orders reads: a read
            // that started before a newer install must not overwrite it.
            if let current = tuiState, current.cursor == nil, incoming.cursor == nil,
               let requestVersion, requestVersion != tuiStateInstallVersion, incoming != current {
                return false
            }
            guard incomingPassesPendingRenameFence(incoming) else {
                #if DEBUG
                cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=pending-rename-fence")
                #endif
                return false
            }
            tuiState = incoming
            tuiStateInstallVersion &+= 1
            equalCursorConflict = nil
            if let generation = incoming.cursor?.generation {
                acceptedTuiGenerations.insert(generation)
            }
            retirePendingRemoteRenames(observed: incoming)
            return true
        case .fetchSnapshot:
            return false
        }
    }
    /// A daemon generation is opaque, but this provider remembers every
    /// generation accepted by the current link lifetime. A response carrying a
    /// previously seen generation after another generation was accepted is an
    /// old-link response and cannot replace the graph.
    private func acceptsIncomingGeneration(_ cursor: TuiCursor?) -> Bool {
        guard let cursor else { return true }
        switch TuiGenerationAcceptanceDecision.resolve(
            incoming: cursor.generation,
            current: tuiState?.cursor?.generation,
            accepted: acceptedTuiGenerations
        ) {
        case .accept: return true
        case .rejectStale: return false
        }
    }
    /// Checks all in-flight rename receipts before a graph becomes visible.
    /// Rejecting the whole graph keeps unrelated rows from being published with
    /// a target row known to be stale at the same cursor.
    private func incomingPassesPendingRenameFence(_ incoming: TuiState) -> Bool {
        for (key, pending) in pendingRemoteRenames {
            let targetMatches: Bool
            switch key {
            case .workspace(let id):
                targetMatches = incoming.lookupIndex.workspace(id: id)?.name == pending.name
            case .tab(let id):
                targetMatches = (incoming.lookupIndex.tab(id: id)?.name ?? "") == pending.name
            }
            switch TuiRemoteMutationReceiptDecision.resolve(
                receipt: pending.receipt,
                incoming: incoming.cursor,
                targetMatches: targetMatches
            ) {
            case .accept:
                continue
            case .rejectStale, .rejectConflict:
                return false
            }
        }
        return true
    }
    /// Retires receipts only after an accepted graph proves that the daemon has
    /// reached them. A later same-generation cursor belongs to the canonical
    /// remote writer, even if it changed the requested name again.
    private func retirePendingRemoteRenames(observed state: TuiState) {
        guard let cursor = state.cursor else { return }
        var completed: [PendingRemoteRenameKey] = []
        for (key, pending) in pendingRemoteRenames {
            let shouldRetire: Bool
            if cursor.generation != pending.receipt.generation {
                // `acceptsIncomingGeneration` already rejected known old
                // generations, so a different accepted generation is current.
                shouldRetire = true
            } else if cursor.revision > pending.receipt.revision {
                shouldRetire = true
            } else if cursor.revision == pending.receipt.revision {
                switch key {
                case .workspace(let id):
                    shouldRetire = state.lookupIndex.workspace(id: id)?.name == pending.name
                case .tab(let id):
                    shouldRetire = (state.lookupIndex.tab(id: id)?.name ?? "") == pending.name
                }
            } else {
                shouldRetire = false
            }
            if shouldRetire {
                completed.append(key)
            }
        }
        for key in completed {
            pendingRemoteRenames.removeValue(forKey: key)
        }
    }
    /// Publishes the authoritative graph and forwarded ports in one catalog transaction.
    func publish(
        _ state: TuiState,
        ports: [Int],
        reconcileTitles: Bool = true,
        observation: TuiStateObservation = .current
    ) {
        guard tuiState == state, canPublishTuiState(state) else { return }
        var resources = CmuxTuiSnapshotParser.resources(from: state)
        resources.append(contentsOf: portResources(ports))
        resources = resourcesWithPendingCreations(resources, state: state)
        if let snapshot = state.snapshotObject() {
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: snapshot)
        }
        info.remoteWorkspaces = remoteWorkspaces(for: state)
        let acceptedObservation = observationWithPendingWrites(observation)
        catalog.replaceTuiState(
            state,
            resources: resources,
            info: info,
            observation: acceptedObservation
        )
        if reconcileTitles {
            catalog.reconcileTuiRemoteState(machine: machine, state: state, observation: acceptedObservation)
        }
        closePanesForVanishedRemoteTerminals(observation: observation)
        syncNotifications(from: state)
    }
    func publishDelta(
        _ state: TuiState,
        impact: TuiStateDeltaImpact,
        ports: [Int],
        reconcileTitles: Bool
    ) {
        guard tuiState == state, canPublishTuiState(state) else { return }
        if impact.requiresFullResourceRebuild {
            publish(state, ports: ports, reconcileTitles: reconcileTitles)
            return
        }
        var affected = impact.resourceIDs
        affected.formUnion(pendingRemoteCreations.keys)
        var resources = CmuxTuiSnapshotParser.resources(from: state, matching: affected)
        resources = resourcesWithPendingCreations(resources, state: state)
        info.remoteWorkspaces = remoteWorkspaces(for: state)
        let previousIDs = Set(catalog.authoritativeSnapshot.resources(on: machine).map(\.id))
        let acceptedObservation = observationWithPendingWrites()
        let changed = catalog.applyTuiStateResourcePatch(
            state,
            resources: resources,
            affectedResourceIDs: affected,
            info: info,
            observation: acceptedObservation
        )
        catalog.reconcileTuiRemoteState(machine: machine, state: state, observation: acceptedObservation)
        if reconcileTitles {
            catalog.tuiWorkspaceRenameService.reconcileRemoteState(
                machine: machine,
                state: state,
                catalog: catalog,
                observation: acceptedObservation,
                affectedResources: affected,
                workspaceNamesChanged: false
            )
        }
        if changed.contains(where: { $0.kind == .terminal && !previousIDs.contains($0) }) {
            reprojectRestoredPanes(generation: lifecycleGeneration)
        }
        closePanesForVanishedRemoteTerminals(observation: .current)
        syncNotifications(from: state)
    }
    /// Closes the panes of terminals the resolver reported as exited. The
    /// graph-driven sweep covers the usual case; this covers a daemon that
    /// still lists an exited terminal because a stale tab row survives it.
    func closePanes(forExitedTerminals terminalIDs: Set<String>) {
        guard !terminalIDs.isEmpty else { return }
        for (panelID, session) in manualMirrorSessions where terminalIDs.contains(session.terminalID) {
            closeManualMirrorPane(panelID: panelID, terminalID: session.terminalID)
        }
    }
    private func closeManualMirrorPane(panelID: UUID, terminalID: String) {
        restoredAttachTasks.removeValue(forKey: panelID)?.cancel()
        materializedPanels.remove(panelID)
        manualMirrorSessions.removeValue(forKey: panelID)?.stop()
        guard let workspace = AppDelegate.shared?.workspace(containingSurfaceID: panelID) else { return }
        SurfacePaneFactory.closeExited(panelID: panelID, in: workspace.id)
    }
    /// Closes attach panes whose remote terminal is gone from the accepted
    /// graph.
    ///
    /// A cloud pane owns no process, so nothing local notices when the remote
    /// shell ends: after `exit` or Ctrl+D the daemon drops the tab and marks
    /// the terminal exited, the byte attachment reports `detached`, and the
    /// session would otherwise keep reconnecting behind a frozen pane. Closing
    /// it here matches a local pane, which disappears when its shell exits, and
    /// it goes through the same close path as the menu, the CLI, and the
    /// keyboard shortcut.
    ///
    /// Only a current graph may close a pane: a stale or unavailable read means
    /// the machine is unreachable, not that the terminal ended.
    private func closePanesForVanishedRemoteTerminals(observation: TuiStateObservation) {
        guard !manualMirrorSessions.isEmpty else { return }
        let resources = catalog.authoritativeSnapshot.resources(on: machine)
        let live = Set(resources.filter { $0.kind == .terminal }.map(\.id.key))
        let boundTerminalIDs = Set(manualMirrorSessions.values.map(\.terminalID))
        let hasMissingTerminalCandidate = !boundTerminalIDs.isSubset(of: live)
        // A complete-graph scan is only needed when cleanup has a terminal it
        // might close. Row-local publications can retire pending overlays, so a
        // cached completeness result would be stale precisely in this case.
        let graphComplete = !hasMissingTerminalCandidate || tuiState.map {
            TuiGraphCompleteness(state: $0, resources: resources).isComplete()
        } ?? false
        let closing = TuiTerminalPaneClosure.panelsToClose(
            boundTerminals: manualMirrorSessions.mapValues(\.terminalID),
            liveTerminalKeys: live,
            freshness: observation.freshness,
            graphComplete: graphComplete
        )
        for panelID in closing {
            guard let terminalID = manualMirrorSessions[panelID]?.terminalID else { continue }
#if DEBUG
            cmuxDebugLog("cloud.pane.closeExited panel=\(panelID) terminal=\(terminalID)")
#endif
            closeManualMirrorPane(panelID: panelID, terminalID: terminalID)
        }
    }

    static func remoteWorkspaces(_ state: TuiState) -> [SurfaceRemoteWorkspace] {
        state.workspaces.map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        }
    }

    private func recordPendingRemoteRename(
        workspaceID: String,
        name: String,
        receipt: TuiCursor
    ) {
        pendingRemoteRenames[.workspace(workspaceID)] = PendingRemoteRename(
            name: name,
            receipt: receipt
        )
        publishPendingMutationMetadata()
    }

    func recordPendingRemoteRename(
        tabID: String,
        name: String,
        receipt: TuiCursor

    ) {
        pendingRemoteRenames[.tab(tabID)] = PendingRemoteRename(
            name: name,
            receipt: receipt
        )
        publishPendingMutationMetadata()
    }

    func pendingRemoteRename(for key: PendingRemoteRenameKey) -> PendingRemoteRename? {
        pendingRemoteRenames[key]
    }

    /// Preserves forwarded-port routes when a cached or unavailable graph is published.
    private func portResources(_ ports: [Int]) -> [SurfaceResource] {
        Self.portResources(machine: machine, scannedPorts: ports, previousResources: catalog.authoritativeSnapshot.resources(on: machine), privateAddress: summary.preferredPrivateAddress)
    }

    /// cmux-tui's `selector.not_found` error body, surfaced by `link.run` as the
    /// command's output text.
    static func isSelectorNotFound(_ error: Error) -> Bool {
        let text = RemoteMachineLink.errorText(error)
        return text.contains("selector.not_found") || text.contains("no terminal matches")
    }

    /// The resource CLI exposes optimistic-concurrency failures as either the
    /// structured code or its human-readable text, depending on client version.
    nonisolated static func isRevisionConflict(_ error: Error) -> Bool {
        let text = RemoteMachineLink.errorText(error).lowercased()
        return text.contains("revision conflict") || text.contains("revision.conflict")
            || text.contains("revision_conflict") || text.contains("stale revision")
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: nil, at: destination, focus: focus)
    }

    func materialize(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: remoteView, at: destination, focus: focus, adopting: nil)
    }

    /// `adopting` binds the attachment to an optimistic pane the workspace already
    /// inserted instead of creating a second one; browsers never reserve panes.
    func materialize(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool,
        adopting reservation: TuiTerminalPaneReservation?
    ) async throws -> SurfaceProjection {
        let created: (workspaceID: UUID, panelID: UUID)
        var createdPlacement: SurfaceRemotePlacement?
        switch resource.kind {
        case .terminal:
            let manual = try await materializeManualMirrorTerminal(
                resource,
                remoteTabID: (remoteView ?? Self.defaultRemoteView(for: resource))?.tabID,
                at: destination,
                focus: focus,
                adopting: reservation
            )
            created = (manual.workspaceID, manual.panelID)
            createdPlacement = manual.remotePlacement
        case .browser:
            created = try await materializeBrowserPane(resource, at: destination, focus: focus)
        }
        materializedPanels.insert(created.panelID)
        if let createdPlacement {
            catalog.tuiPlacementCoordinator.confirmPlacement(createdPlacement, on: machine)
        }
        let selectedView = remoteView ?? Self.defaultRemoteView(for: resource)
        return SurfaceProjection(
            resource: resource.id,
            workspaceID: created.workspaceID,
            panelID: created.panelID,
            remoteWorkspaceID: createdPlacement?.workspaceID ?? selectedView?.workspace.id,
            remoteTabID: createdPlacement?.tabID ?? selectedView?.tabID
        )
    }

    func recordCreatedTerminal(
        _ created: CmuxTuiSnapshotParser.CreatedTerminalPath,
        workspaceID: String,
        name: String?,
        cwd: String?
    ) -> SurfaceResource {
        let resolvedWorkspaceID = created.workspaceID ?? workspaceID
        let remoteWorkspace = tuiState?.workspaces.first(where: { $0.id == resolvedWorkspaceID }).map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        } ?? info.remoteWorkspaces?.first(where: { $0.id == resolvedWorkspaceID })
            ?? SurfaceRemoteWorkspace(
                id: resolvedWorkspaceID,
                name: resolvedWorkspaceID,
                index: info.remoteWorkspaces?.count ?? 0,
                focused: false
            )
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: created.terminalID),
            title: name ?? "",
            detail: cwd,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            port: nil,
            url: nil
        )
        resource.creationAttachment = created.attachment
        if let tabID = created.tabID {
            resource.remoteViews = [SurfaceRemoteView(
                tabID: tabID,
                workspace: remoteWorkspace,
                screenID: created.screenID,
                paneID: created.paneID,
                name: name,
                focused: true
            )]
        } else {
            resource.remoteViews = []
        }
        pendingRemoteCreations[resource.id] = PendingRemoteCreation(
            resource: resource,
            receipt: created.cursor,
            tabID: created.tabID
        )
        catalog.upsert(resource, from: self)
        publishPendingMutationMetadata()
        scheduleRefresh()
        return resource
    }

    /// A new workspace in the machine's cmux-tui session (`workspace create`),
    /// called directly — not as a side effect of creating a terminal.
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        let receipt = try await createRemoteWorkspaceReceipt(name: name)
        return info.remoteWorkspaces?.first(where: { $0.id == receipt.workspace.id }) ?? receipt.workspace
    }

    func createRemoteWorkspaceReceipt(name: String?) async throws -> SurfaceWorkspaceCreationReceipt {
        try await createRemoteWorkspaceReceipt(name: name, expectedRevision: nil)
    }

    /// Uses the daemon's revision fence for the name lookup/create, including
    /// races with another Mac or a guest CLI, without serializing unrelated I/O.
    func getOrCreateRemoteWorkspace(name: String) async throws -> (workspace: SurfaceRemoteWorkspace, existing: Bool) {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        for attempt in 0..<8 {
            try Task.checkCancellation()
            let data = try await link.run(arguments: TuiRequests.snapshotArguments(socketPath: connected.socketPath))
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine),
                  let revision = state.cursor?.revision else { throw ProviderError.invalidSnapshot(machineID) }
            let matches = CmuxTuiSnapshotParser.workspaces(fromSnapshot: snapshot).filter { $0.name == name }
            if matches.count > 1 {
                throw SurfaceCatalogError.destinationNotFound(String(localized: "cloud.workspace.ambiguousName", defaultValue: "Several machine workspaces have that name. Use a workspace ID or choose a unique name."))
            }
            if let workspace = matches.first { return (workspace, true) }
            do {
                return (try await createRemoteWorkspaceReceipt(name: name, expectedRevision: revision).workspace, false)
            } catch let error as RemoteMachineLink.LinkError {
                guard attempt < 7, case .exited(_, let output) = error,
                      let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                      (object["code"] as? String) == "revision.conflict" else { throw error }
            }
        }
        throw ProviderError.invalidSnapshot(machineID)
    }

    private func createRemoteWorkspaceReceipt(name: String?, expectedRevision: UInt64?) async throws -> SurfaceWorkspaceCreationReceipt {
        let generation = lifecycleGeneration
        try Task.checkCancellation()
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        let workspaceName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = TuiRequests.createWorkspaceArguments(socketPath: connected.socketPath, name: workspaceName)
        if let expectedRevision { arguments = arguments.adding(["expected_revision": String(expectedRevision)]) }
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { throw CancellationError() }
        let created = try await link.run(arguments: arguments)
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { throw CancellationError() }
        guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        // Creation already committed. Retain its exact starter receipt while a
        // delayed snapshot catches up, so the caller cannot create a second one.
        let committedName = ((object["value"] as? [String: Any]) ?? object)["name"] as? String
        let provisionalName = workspaceName?.isEmpty == false
            ? workspaceName!
            : (committedName ?? String(localized: "tuiTree.workspace.pending", defaultValue: "New workspace"))
        let provisional = SurfaceRemoteWorkspace(id: id, name: provisionalName, index: info.remoteWorkspaces?.count ?? 0, focused: false)
        if info.remoteWorkspaces?.contains(where: { $0.id == id }) != true {
            info.remoteWorkspaces = (info.remoteWorkspaces ?? []) + [provisional]
            catalog.updateMachine(info, from: self)
        }
        let starter = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object)
        let terminal = starter.map { recordCreatedTerminal($0, workspaceID: id, name: nil, cwd: nil) }
        scheduleRefresh()
        return SurfaceWorkspaceCreationReceipt(
            workspace: info.remoteWorkspaces?.first(where: { $0.id == id }) ?? provisional,
            terminal: terminal,
            cursor: starter?.cursor ?? CmuxTuiSnapshotParser.mutationCursor(fromResult: object)
        )
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
        try Task.checkCancellation()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "tuiTree.error.renameWorkspaceEmptyName", defaultValue: "A workspace name cannot be empty.")
            )
        }
        // Validate against a fresh document. A cached workspace id can refer to
        // a closed or recycled daemon object after another client changes the VM.
        guard await refreshCurrentGraph(force: true),
              let observed = tuiState,
              let previous = observed.workspaces.first(where: { $0.id == id }) else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "tuiTree.error.renameWorkspaceNotFound", defaultValue: "This remote workspace is no longer available.")
            )
        }
        guard let observedCursor = observed.cursor else {
            throw ProviderError.snapshotOnly(machineID)
        }
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        try Task.checkCancellation()
        do {
            let receipt = try await sendRenameWorkspace(
                link: link,
                socketPath: connected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: observedCursor.revision
            )
            recordPendingRemoteRename(workspaceID: id, name: normalizedName, receipt: try validatedReceipt(receipt, against: observedCursor))
        } catch {
            // A revision can advance for an unrelated event. Retry once only
            // when this workspace still has the name we observed. If another
            // client changed it, do not overwrite that intent.
            guard Self.isRevisionConflict(error),
                  await refreshCurrentGraph(force: true),
                  let latest = tuiState,
                  let current = latest.workspaces.first(where: { $0.id == id }),
                  let latestCursor = latest.cursor,
                  current.name == previous.name else { throw error }
            let retryConnected = try await links.connected(machineID: machineID)
            guard let retryLink = await links.link(machineID: machineID) else { throw error }
            let retryReceipt = try await sendRenameWorkspace(
                link: retryLink,
                socketPath: retryConnected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: latestCursor.revision
            )
            recordPendingRemoteRename(workspaceID: id, name: normalizedName, receipt: try validatedReceipt(retryReceipt, against: latestCursor))
        }
        // The command response is not the source of truth. Wait for the next
        // accepted snapshot/event so every local projection sees the same name.
        try Task.checkCancellation()
        _ = await refreshCurrentGraph(force: true)
    }

    /// Compatibility operation for callers that intentionally mean “all views”.
    /// It is kept separate from `renameRemoteTab` so an ambiguous terminal identity
    /// can never silently rename an arbitrary placement.
    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
        try Task.checkCancellation()
        let normalizedName = TuiRemoteRenameName(rawValue: name).wireValue
        // The daemon's tab name is placement-local. Keep one target per exact
        // tab id, and use the fresh typed state for the old value. A creation
        // receipt supplies the one exact tab while the first snapshot catches
        // up, so an immediate rename cannot lose its target.
        let refreshEstablishedCurrentGraph = await refreshCurrentGraph(force: true)
        try Task.checkCancellation()
        let pending = pendingCreation(for: id)
        let observed = tuiState
        // Derive every placement from the freshly accepted canonical graph. The
        // catalog is a projection and may still contain a row from an older
        // publication, so it cannot authorize a compatibility fan-out.
        let freshTargets: [(tabID: String, previousName: String)] = {
            guard refreshEstablishedCurrentGraph,
                  let observed,
                  observed.cursor != nil,
                  observed.lookupIndex.terminal(id: id.key) != nil else { return [] }
            return observed.lookupIndex
                .tabs(contentKind: "terminal", contentID: id.key)
                .map { ($0.id, $0.name ?? "") }
        }()
        let authority = TuiRemoteMutationAuthority.resolve(
            refreshEstablishedCurrentGraph: refreshEstablishedCurrentGraph,
            hasAcceptedState: observed != nil,
            targetVisible: !freshTargets.isEmpty,
            hasVersionedCursor: observed?.cursor != nil,
            hasPendingReceipt: pending?.tabID != nil && pending?.receipt != nil
        )
        let observedCursor: TuiCursor
        let targets: [(tabID: String, previousName: String)]
        switch authority {
        case .currentGraph:
            guard let cursor = observed?.cursor, !freshTargets.isEmpty else {
                throw ProviderError.stateUnavailable(machineID)
            }
            observedCursor = cursor
            targets = freshTargets
        case .pendingReceipt:
            guard let pending,
                  let receipt = pending.receipt,
                  let tabID = pending.tabID else {
                throw ProviderError.stateUnavailable(machineID)
            }
            observedCursor = receipt
            let previousName = pending.resource.remoteViews?.first(where: { $0.tabID == tabID })?.name ?? ""
            targets = [(tabID, previousName)]
        case .snapshotOnly:
            throw ProviderError.snapshotOnly(machineID)
        case .unavailable:
            throw ProviderError.stateUnavailable(machineID)
        case .targetMissing:
            throw SurfaceCatalogError.unsupported(
                String(localized: "tuiTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }

        // A same-text user rename must still claim an automatic name.
        let pendingTargets = targets.filter {
            $0.previousName != normalizedName || observed?.lookupIndex.tab(id: $0.tabID)?.nameAuthority?.source == .auto
        }
        if pendingTargets.isEmpty { return }

        var lastCommitCursor = observedCursor
        var renamedTabs: [(tabID: String, previousName: String, commitCursor: TuiCursor)] = []
        var mutationOutcomeUncertain = false
        do {
            for target in pendingTargets {
                try Task.checkCancellation()
                do {
                    let receipt = try await sendRenameTab(
                        id: target.tabID,
                        name: normalizedName,
                        expectedRevision: lastCommitCursor.revision
                    )
                    let validated = try validatedReceipt(receipt, against: lastCommitCursor)
                    renamedTabs.append((target.tabID, target.previousName, validated))
                    lastCommitCursor = validated
                    recordPendingRemoteRename(tabID: target.tabID, name: normalizedName, receipt: validated)
                    recordPendingRename(tabID: target.tabID, name: normalizedName, revision: validated.revision)
                } catch {
                    // A revision conflict is a known refusal before this step
                    // commits. Transport or malformed-response errors are
                    // indeterminate: the daemon may have committed before the
                    // link failed, so compensation would be unsafe.
                    if !Self.isRevisionConflict(error) { mutationOutcomeUncertain = true }
                    throw error
                }
            }
        } catch {
            // Compensation is allowed only when a fresh snapshot proves that
            // no event followed the last known commit and every completed tab
            // still carries our requested name. Each restore is itself fenced,
            // so a concurrent rename between checks cannot be overwritten.
            var compensated = renamedTabs.isEmpty
            if !renamedTabs.isEmpty, !mutationOutcomeUncertain,
               await refreshCurrentGraph(force: true),
               let latest = tuiState,
               let latestCursor = latest.cursor,
               latestCursor.generation == observedCursor.generation,
               latestCursor == lastCommitCursor,
               renamedTabs.allSatisfy({ entry in
                   latest.lookupIndex.tab(id: entry.tabID)?.name == normalizedName
               }) {
                compensated = true
                var compensationCursor = latestCursor
                for entry in renamedTabs.reversed() {
                    do {
                        let receipt = try await sendRenameTab(
                            id: entry.tabID,
                            name: entry.previousName,
                            expectedRevision: compensationCursor.revision
                        )
                        let validated = try validatedReceipt(receipt, against: compensationCursor)
                        compensationCursor = validated
                        recordPendingRemoteRename(tabID: entry.tabID, name: entry.previousName, receipt: validated)
                        recordPendingRename(tabID: entry.tabID, name: entry.previousName, revision: validated.revision)
                    } catch {
                        compensated = false
                        break
                    }
                }
            }
            _ = await refreshCurrentGraph(force: true)
            if !compensated {
                throw Self.partialRenameError(
                    id: id,
                    applied: renamedTabs.count,
                    total: pendingTargets.count
                )
            }
            throw error
        }
        _ = await refreshCurrentGraph(force: true)
    }

    @discardableResult
    private func sendRenameWorkspace(
        link: RemoteMachineLink,
        socketPath: String,
        workspaceID: String,
        name: String,
        expectedRevision: UInt64?
    ) async throws -> TuiCursor? {
        let data = try await link.run(arguments: TuiRequests.renameWorkspaceArguments(
            socketPath: socketPath,
            workspaceID: workspaceID,
            name: name,
            expectedRevision: expectedRevision
        ))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteRenameError.invalidResponse
        }
        return CmuxTuiSnapshotParser.mutationCursor(fromResult: object)
    }

    func sendRenameTab(id: String, name: String, expectedRevision: UInt64? = nil) async throws -> TuiCursor {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        let data = try await link.run(arguments: TuiRequests.renameTabArguments(
            socketPath: connected.socketPath,
            tabID: id,
            name: name,
            expectedRevision: expectedRevision
        ))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteRenameError.invalidResponse
        }
        guard let receipt = CmuxTuiSnapshotParser.mutationCursor(fromResult: object) else {
            throw RemoteRenameError.invalidResponse
        }
        return receipt
    }

    func validatedReceipt(
        _ receipt: TuiCursor?,
        against expected: TuiCursor
    ) throws -> TuiCursor {
        guard let receipt else { throw RemoteRenameError.invalidResponse }
        guard receipt.generation == expected.generation else {
            throw RemoteRenameError.generationChanged(expected: expected.generation, received: receipt.generation)
        }
        guard receipt.revision > expected.revision else {
            throw RemoteRenameError.nonMonotonicRevision(
                expectedAtLeast: expected.revision == UInt64.max ? UInt64.max : expected.revision + 1,
                received: receipt.revision
            )
        }
        return receipt
    }

    private enum RemoteRenameError: Error, LocalizedError {
        case invalidResponse
        case generationChanged(expected: String, received: String)
        case nonMonotonicRevision(expectedAtLeast: UInt64, received: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "tuiTree.error.renameTerminalResponse", defaultValue: "The remote rename response was invalid. Refresh and retry.")
            case .generationChanged:
                return String(localized: "tuiTree.error.renameTerminalGeneration", defaultValue: "The remote rename came from a different SSH session. Refresh and retry.")
            case .nonMonotonicRevision(let expected, let received):
                return String(format: String(localized: "tuiTree.error.renameTerminalRevision", defaultValue: "The remote rename returned revision %2$llu after revision %1$llu. Refresh and retry."), expected, received)
            }
        }
    }

    private static func partialRenameError(
        id: SurfaceResourceID,
        applied: Int,
        total: Int
    ) -> SurfaceCatalogError {
        let reason = String(format: String(
            localized: "tuiTree.error.renameTerminalPartial",
            defaultValue: "Terminal rename changed %1$d of %2$d remote tabs. Another change prevented a safe rollback. Refresh and retry."
        ), applied, total)
        return .partialOperation(id, reason: reason)
    }

    /// The terminal lives in the machine's session; only the local pane went away.
    func projectionDidEnd(_ projection: SurfaceProjection) {
        browserPaneTasks.removeValue(forKey: projection.panelID)?.cancel()
        restoredAttachTasks.removeValue(forKey: projection.panelID)?.cancel()
        materializedPanels.remove(projection.panelID)
        manualMirrorSessions.removeValue(forKey: projection.panelID)?.stop()
    }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        browserPaneTasks.removeValue(forKey: projection.panelID)?.cancel()
        restoredAttachTasks.removeValue(forKey: projection.panelID)?.cancel()
        materializedPanels.remove(projection.panelID)
        manualMirrorSessions.removeValue(forKey: projection.panelID)?.stop()
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }

    // MARK: - internals

    /// Appends preserved resources without repeatedly scanning the growing
    /// snapshot array. Refresh fallback paths run on the main actor, so keeping
    /// this linear is important for machines with many remote views.
    private func appendMissingResources(
        _ preserved: [SurfaceResource],
        to resources: inout [SurfaceResource]
    ) {
        var knownIDs = Set(resources.map(\.id))
        for resource in preserved where knownIDs.insert(resource.id).inserted {
            resources.append(resource)
        }
    }

    private func attachCommand(terminalID: String) async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let clientURL = TuiClientPaths.clientURL() else {
            throw TuiTransportError.unsupported
        }
        return TuiCommandLine.attachShellCommand(clientPath: clientURL.path, socketPath: connected.socketPath, terminalID: terminalID)
    }

    static func paneLabel(machineID: String, port: Int) -> String {
        "\(machineID):\(port)"
    }

    /// Turn a VM-local browser URL into the same URL on the VM private address.
    /// Path, query, fragment, scheme, and port stay unchanged.
    nonisolated static func privateBrowserURL(_ raw: String, privateAddress: String, allowLoopback: Bool = false) -> String? {
        guard let parts = URLComponents(string: raw),
              RemoteLoopbackProxyAlias.isLoopbackHost(parts.host ?? "") else { return nil }
        return RemotePortRoutePolicy().privateURL(raw, address: privateAddress, allowLoopback: allowLoopback)?.absoluteString
    }

    /// Shared Cloud terminal-link conversion for Workspace and Dock containers.
    nonisolated static func tuiTerminalLinkTarget(url: URL, resource: SurfaceResource, privateAddress: String) -> RemoteTerminalLinkTarget? {
        guard resource.kind == .terminal, resource.machine.tuiMachineID != nil,
              let rewritten = privateBrowserURL(url.absoluteString, privateAddress: privateAddress, allowLoopback: resource.machine.isSSH),
              let privateURL = URL(string: rewritten) else { return nil }
        return RemoteTerminalLinkTarget(url: privateURL)
    }

    /// Add the local URL used when this resource is projected on the Mac.
    nonisolated static func withPrivateBrowserURL(
        _ resource: SurfaceResource,
        privateAddress: String
    ) -> SurfaceResource {
        var updated = resource
        switch resource.kind {
        case .browser:
            if resource.id.key.hasPrefix("port:"), let port = resource.port {
                updated.url = CmuxInternalHostnames().directPortURL(
                    privateAddress: privateAddress,
                    port: port
                )
            } else if let raw = resource.url {
                updated.url = privateBrowserURL(raw, privateAddress: privateAddress, allowLoopback: resource.machine.isSSH)
            }
        case .terminal:
            break
        }
        return updated
    }

    /// A forwarded-port pane, live or staged by session restore, is standing
    /// scan demand: a restored port resource exists only after a scan
    /// publishes it, so without this the staged pane can never resolve.
    private var hasProjectedPortPanes: Bool {
        catalog.pendingRestoredProjections.projections.contains { $0.resource.machine == machine && $0.resource.isForwardedPort }
            || catalog.projections.contains { $0.resource.machine == machine && $0.resource.isForwardedPort }
    }

    private func ports(link: RemoteMachineLink, socketPath: String, force: Bool, lifecycle: UInt64, privateAddress: String?) async -> [Int]? {
#if DEBUG
        cmuxDebugLog("cloud.portScan.begin machine=\(machineID) requested=\(portDiscovery.wasRequested) force=\(force)")
#endif
        if !portDiscovery.wasRequested, hasProjectedPortPanes { requestPortDiscovery() }
        guard portDiscovery.mayScan else { return portsCache?.ports }
        let previousState = portDiscovery.state
        if let cached = portDiscovery.cachedScan(at: Date.now, socketPath: socketPath, force: force) {
            if portDiscovery.state != previousState { publishPortDiscovery() }
            return cached.ports.filter {
                !CmuxTuiSnapshotParser.internalPorts.contains($0)
            }
        }
        // The request id, not the refresh generation, fences this scan: routine
        // summary polls bump the generation mid-scan, while a newer scan, route
        // change, or link failure supersedes the request.
        let request = portDiscovery.beginScan()
        defer { portDiscovery.endScan(request) }
        guard let arguments = TuiRequests.listeningPortsArguments(socketPath: socketPath),
              let data = try? await link.run(arguments: arguments),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdout = object["stdout"] as? String else {
#if DEBUG
            cmuxDebugLog("cloud.portScan.failed machine=\(machineID) reason=transport")
#endif
            // A cancelled scan belongs to whichever pass cancelled it.
            guard isCurrentLifecycleGeneration(lifecycle), !Task.isCancelled else { return nil }
            if portDiscovery.complete(nil, request: request, at: Date.now, socketPath: socketPath) {
                publishPortDiscovery()
            }
            return nil
        }
        guard isCurrentLifecycleGeneration(lifecycle) else { return nil }
        let scan = Self.portScan(from: stdout)
#if DEBUG
        cmuxDebugLog("cloud.portScan.result machine=\(machineID) ports=\(scan?.ports.map(String.init).joined(separator: ",") ?? "nil") bytes=\(stdout.utf8.count)")
#endif
        guard portDiscovery.complete(scan, request: request, at: Date.now, socketPath: socketPath) else { return nil }
        publishPortDiscovery()
        guard let scan else { return nil }
        settleRestoredPortPanes(scannedPorts: scan.ports)
        portsCache = (scan.ports, Date.now)
        return scan.ports
    }

    private func watchChanges(link: RemoteMachineLink, generation: UInt64) {
        guard generation == lifecycleGeneration else { return }
        if let watchedLink, watchedLink === link, changeWatcher != nil { return }
        changeWatcher?.cancel()
        let watcherID = UUID()
        watchedLink = link
        changeWatcherID = watcherID
        changeWatcher = Task { [weak self] in
            for await change in link.changes {
                guard let self else { return }
                guard self.lifecycleGeneration == generation else { return }
                await self.handle(change, from: link)
            }
            await MainActor.run { [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.changeWatcherDidEnd(watcherID)
            }
        }
    }
    private func changeWatcherDidEnd(_ watcherID: UUID) {
        guard changeWatcherID == watcherID else { return }
        changeWatcher = nil
        watchedLink = nil
        changeWatcherID = nil
        catalog.markTuiStateStale(on: machine, reason: "event_feed_ended")
        scheduleRefresh()
    }
    private func handle(_ change: RemoteMachineLink.Change, from link: RemoteMachineLink) async {
        // Events from a retired link can arrive after a reconnect. They are
        // never allowed to mutate the graph owned by the replacement link.
        guard watchedLink === link else { return }
        switch change {
        case .connected:
            guestURLService?.stop()
            notificationSync?.linkDidConnect()
            // A recovered user SSH link retries durable reads immediately and
            // refreshes the accepted graph before projecting terminals and ports.
            scheduleRefresh(force: true)
        case .snapshot(let cursor, _, let payload):
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let incoming = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
                  incoming.cursor == cursor else {
                scheduleStateRecoveryRefresh()
                return
            }
            if installSnapshotIfNewer(incoming) {
                clearStateRecovery()
                await link.setEventsCursor(incoming.cursor)
                guard watchedLink === link, canPublishTuiState(incoming) else { return }
                var subscriptionResumed = false
                if let cursor = incoming.cursor {
                    subscriptionResumed = await link.resumeEventsSubscription(from: cursor)
                }
                guard watchedLink === link, canPublishTuiState(incoming) else { return }
                if TuiEventFeedRecoveryDecision.shouldClearWarning(
                    snapshotCursor: incoming.cursor,
                    subscriptionResumed: subscriptionResumed
                ) {
                    eventsFeedWarning = nil
                }
                info.linkState = .connected
                info.linkError = nil
                publish(incoming, ports: portsCache?.ports ?? [])
                reprojectRestoredPanes(generation: lifecycleGeneration)
            }
        case .delta(let cursor, let previousRevision, let revision, let payload):
            switch TuiStateSyncDecision.forDelta(
                generation: cursor.generation,
                previousRevision: previousRevision,
                revision: revision,
                current: tuiState?.cursor
            ) {
            case .ignoreStale:
                return
            case .fetchSnapshot:
                // A gap is the same synchronization barrier as a malformed event. Route it
                // through the single bounded recovery owner so a burst of out-of-order events
                // cannot start one full snapshot request per line.
                #if DEBUG
                cmuxDebugLog("cloud.state.deltaGap machine=\(machineID) previous=\(previousRevision) revision=\(revision) current=\((tuiState?.cursor?.revision).map(String.init) ?? "nil")")
                #endif
                scheduleStateRecoveryRefresh()
            case .installSnapshot:
                #if DEBUG
                if let current = tuiState, cursor.revision != revision {
                    cmuxDebugLog("cloud.state.deltaRejectReason reason=itemRevision cursor=\(cursor.revision) revision=\(revision) current=\(current.cursor?.revision ?? 0)")
                }
                #endif
                guard let current = tuiState,
                      cursor.revision == revision,
                      let application = CmuxTuiSnapshotParser.applyingWithImpact(
                        deltaPayload: payload,
                        cursor: cursor,
                        to: current
                      ),
                      application.state.cursor == cursor else {
                    #if DEBUG
                    let kinds = ((try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["changes"] as? [[String: Any]])?
                        .compactMap { "\($0["kind"] ?? "?"):\($0["resource"] ?? "?")" }.joined(separator: ",") ?? "?"
                    cmuxDebugLog("cloud.state.deltaRejected machine=\(machineID) revision=\(revision) changes=\(kinds)")
                    #endif
                    scheduleStateRecoveryRefresh()
                    return
                }
                let next = application.state
                guard acceptsIncomingGeneration(next.cursor),
                      incomingPassesPendingRenameFence(next) else {
                    // A contiguous delta that still precedes or contradicts a
                    // mutation receipt is a synchronization barrier. Keep the
                    // last accepted graph and ask for one complete snapshot.
                    scheduleStateRecoveryRefresh()
                    return
                }
                tuiState = next
                tuiStateInstallVersion &+= 1
                acceptedTuiGenerations.insert(cursor.generation)
                retirePendingRemoteRenames(observed: next)
                eventsFeedWarning = nil
                clearStateRecovery()
                // The cursor moved on, so an armed conflict no longer applies.
                equalCursorConflict = nil
                await link.setEventsCursor(next.cursor)
                guard watchedLink === link, canPublishTuiState(next) else { return }
                info.linkState = .connected
                info.linkError = nil
                let titlesChanged = current.workspaces != next.workspaces || current.tabs != next.tabs
                publishDelta(
                    next,
                    impact: application.impact,
                    ports: portsCache?.ports ?? [],
                    reconcileTitles: titlesChanged
                )
            }
        case .streamEnded(let reason, _):
            // A stream gap, unknown item, or transport end is a full-state
            // barrier. The snapshot command is the only safe recovery source;
            // RemoteMachineLink owns bounded event-feed recovery. The provider
            // must not independently restart the same stream.
            if reason == RemoteMachineLink.eventsRecoveryExhaustedReason {
                eventsFeedWarning = reason
            }
            scheduleStateRecoveryRefresh()
        case .unknown:
            // An unknown item is a synchronization barrier, but it is not proof that the
            // transport is dead. Coalesce the expensive snapshot repair and stop after a small
            // bounded number of recovery attempts from one broken stream.
            scheduleStateRecoveryRefresh()
        }
    }
    /// Coalesces event-feed barriers behind bounded snapshot recovery. Until it succeeds,
    /// retained graph data is diagnostic history, not a current directory report.
    private func scheduleStateRecoveryRefresh() {
        catalog.markTuiStateStale(on: machine, reason: "event_feed_recovery")
        guard stateRecoveryCount < Self.stateRecoveryLimit else {
            eventsFeedWarning = "state_recovery_exhausted"
            stateRecoveryRefreshQueued = false
            return
        }
        stateRecoveryCount += 1
        stateRecoveryRefreshQueued = true
        guard stateRecoveryRefreshTask == nil else { return }
        stateRecoveryRefreshTask = Task { @MainActor [weak self] in
            // Yield one actor turn to coalesce a burst of barrier events. This is
            // an ordering boundary, not a guessed transport delay.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.stateRecoveryRefreshTask = nil
            guard self.stateRecoveryRefreshQueued else { return }
            self.stateRecoveryRefreshQueued = false
            await self.refreshCurrentGraph(force: true)
            if self.stateRecoveryRefreshQueued {
                self.scheduleStateRecoveryRefresh()
            }
        }
    }
    private func clearStateRecovery() {
        stateRecoveryRefreshTask?.cancel()
        stateRecoveryRefreshTask = nil
        stateRecoveryRefreshQueued = false
        stateRecoveryCount = 0
    }
    /// Mutations also request a snapshot as a safety check. One main-actor yield
    /// coalesces calls made in the same transaction without adding a time guess.
    func reconcileRemovedRemoteWorkspace(_ id: String) { info.remoteWorkspaces = info.remoteWorkspaces?.filter { $0.id != id }; catalog.updateMachine(info, from: self) }
    func scheduleRefresh(force: Bool = false) {
        let lifecycle = lifecycleGeneration
        scheduledRefreshForce = scheduledRefreshForce || force
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.scheduledRefresh = nil
            let requestedForce = self.scheduledRefreshForce
            self.scheduledRefreshForce = false
            guard self.lifecycleGeneration == lifecycle, self.isRegisteredInCatalog() else { return }
            await self.refreshCurrentGraph(force: requestedForce)
        }
    }
    func projectionsRestored() { reprojectRestoredPanes(generation: lifecycleGeneration) }
    /// Rebinds only the resource projections resolved by the latest catalog publication.
    func projectionsRestored(resources: Set<SurfaceResourceID>) {
        reprojectRestoredPanes(generation: lifecycleGeneration, resourceIDs: resources)
    }
    private func reprojectRestoredPanes(generation: UInt64, resourceIDs: Set<SurfaceResourceID>? = nil) {
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { return }
        // Browser and port projections have their own reachability state. A
        // stale terminal graph must not strand those unrelated panes.
        reprojectRestoredBrowserPanes(generation: generation, resourceIDs: resourceIDs)
        let projectionsByResource = resourceIDs.map { catalog.projections(of: $0) }
        let terminals = catalog.authoritativeSnapshot.resources(on: machine).filter {
            $0.kind == .terminal && (resourceIDs == nil || resourceIDs!.contains($0.id))
        }
        for terminal in terminals {
            for projection in (resourceIDs == nil ? catalog.projections(of: terminal.id) : projectionsByResource?[terminal.id] ?? []) where !materializedPanels.contains(projection.panelID) {
                guard tuiState.map({ catalog.tuiWorkspaceProjectionCoordinator.retainsProjection(projection, in: $0) }) != false,
                      let workspace = AppDelegate.shared?.workspace(containingSurfaceID: projection.panelID),
                      let paneID = SurfacePaneFactory.paneID(ofPanel: projection.panelID, in: projection.workspaceID) else {
                    continue
                }
                if let reservation = workspace.tuiPendingCreations[projection.panelID] {
                    attachReservedTerminalPane(reservation, resource: terminal, remoteTabID: projection.remoteTabID)
                    continue
                }
                // Claimed before any async hop so a burst of refreshes cannot re-project twice.
                materializedPanels.insert(projection.panelID)
                guard let reservation = workspace.reserveTuiTerminalPane(
                    machine: machine,
                    at: .tab(workspaceID: projection.workspaceID, paneID: paneID, index: nil),
                    focus: false,
                    attachmentPlacement: SurfaceResourcePlacement(resource: projection.resource, remoteWorkspaceID: projection.remoteWorkspaceID, remoteTabID: projection.remoteTabID)
                ) else {
                    materializedPanels.remove(projection.panelID)
                    continue
                }
                catalog.replaceProjection(projection, withPanel: reservation.panelID, in: projection.workspaceID, remotePlacement: nil, preservingSavedPlacement: true)
                workspace.clearTuiMaterializationFailure(surfaceID: projection.panelID)
                SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
                attachReservedTerminalPane(reservation, resource: terminal, remoteTabID: projection.remoteTabID)
            }
        }
    }
}

extension SurfaceMachineInfo {
    /// Copy for a failed remote graph refresh. State-specific failures take precedence over
    /// diagnostics because a missing graph is not necessarily a network failure. Internal
    /// snake-case reason codes stay out of user-facing errors.
    var linkFailureMessage: String {
        switch linkState {
        case .unavailable:
            return String(localized: "ssh.tui.hostUnavailable", defaultValue: "cmux cannot reach this SSH host. Check the host and reconnect.")
        default:
            guard let linkError else { return TuiTransportError.connectionClosed.localizedDescription }
            let message = linkError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty,
                  message.range(of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$"#, options: .regularExpression) == nil else {
                return TuiTransportError.connectionClosed.localizedDescription
            }
            return message
        }
    }

    /// The same machine row with `previous`'s resource gauges, so a refresh that
    /// publishes before its stats read lands does not blank the sidebar gauges.
    func carryingGauges(from previous: SurfaceMachineInfo) -> SurfaceMachineInfo {
        var info = self
        info.memoryMb = previous.memoryMb
        info.diskMb = previous.diskMb
        info.cpuPercent = previous.cpuPercent
        info.memoryUsedMb = previous.memoryUsedMb
        info.diskUsedMb = previous.diskUsedMb
        return info
    }

}