import CmuxRemoteSession
import CmuxTui
import CmuxSurfaceCatalogModel
import CmuxFoundation
import Foundation

extension CmuxTuiSurfaceProvider {
    // MARK: Notifications
    func installNotificationSync() {
        let machineID = self.machineID
        let clientID = TuiClientPaths().notificationClientID()
        let hub = catalog.tuiNotificationSyncHub
        let sync = TuiNotificationSync(
            machineID: machineID,
            clientID: clientID, store: hub.persistenceStore,
            resolveTarget: { [weak self] row in self?.notificationDeliveryTarget(for: row) },
            deliver: { [weak self] row, target in self?.deliverNotification(row, to: target) ?? .declined },
            send: { [weak self] batch in
                // A vanished provider must not report success: the batch stays
                // pending in the durable state for the replacement sync.
                guard let self else { throw ProviderError.connectionUnavailable(machineID) }
                let connected = try await self.links.connected(machineID: machineID)
                guard let link = await self.links.link(machineID: machineID) else {
                    throw ProviderError.connectionUnavailable(machineID)
                }
                _ = try await link.run(arguments: TuiRequests.notificationAckArguments(
                    socketPath: connected.socketPath,
                    clientID: clientID,
                    notificationIDs: batch.ids,
                    idempotencyKey: batch.key
                ))
            },
            unreadChanged: { terminalIDs in
                hub.setUnread(terminalIDs, machineID: machineID)
            },
            withdraw: { ids in
                // `cmux notify --clear` on the machine, or ledger eviction:
                // the local banners for those rows go with them.
                guard let store = AppDelegate.shared?.notificationStore else { return }
                let removedIDs = Set(ids)
                for notification in store.notifications where notification.correlationKey.map({ TuiNotificationCorrelation.matches($0, machineID: machineID, notificationIDs: removedIDs) }) == true {
                    store.remove(id: notification.id)
                }
            }
        )
        notificationSync = sync
        hub.register(sync)
        notificationPlacementObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: catalog,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRegisteredInCatalog(), let state = self.tuiState,
                      self.catalog.tuiStateObservations[self.machine]?.freshness == .current else { return }
                self.syncNotifications(from: state)
            }
        }
    }
    func syncNotifications(from state: TuiState) {
        guard isRegisteredInCatalog(), !isRetired, catalog.tuiStateObservations[machine]?.freshness == .current else { return }
        if notificationSync == nil { installNotificationSync() }
        syncAgentHooks(from: state)
        updateGuestURLMembership()
        guestURLService?.recoverOnLinkProgress()
        guard let notificationSync else { return }
        let rows = TuiNotificationRow.rows(from: state)
        notificationSync.apply(rows: rows)
        #if DEBUG
        cmuxDebugLog("SSH.notifications.sync machine=\(machineID) revision=\((state.cursor?.revision).map(String.init) ?? "nil") rows=\(rows.count) unreadTerminals=\(notificationSync.unreadTerminalIDs.count) pending=\(notificationSync.state.pendingAcks.count)")
        #endif
    }
    // MARK: Agent hooks
    /// The remote workspaces whose tabs show `terminalID` in the accepted graph,
    /// in graph order. Hook routing and notification placement both use it.
    nonisolated static func remoteWorkspaceIDs(showing terminalID: String, in state: TuiState) -> [String] {
        state.tabs.compactMap { tab in
            guard tab.contentID == terminalID,
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { return nil }
            return screen.workspaceID
        }
    }

    /// Selects the pane for a mirrored hook from the terminal's catalog projections.
    ///
    /// `remoteWorkspaceIDs` are the remote workspaces the accepted daemon graph
    /// shows the terminal in, in graph order. A projection in one of them wins;
    /// otherwise a projection with no workspace identity (a legacy or restored
    /// record) does. A terminal whose projections all name other workspaces
    /// fails closed rather than sending the hook to an adjacent local pane.
    nonisolated static func mirroredAgentHookProjection(
        projections: [SurfaceProjection],
        remoteWorkspaceIDs: [String]
    ) -> SurfaceProjection? {
        let remoteWorkspaceIDs = remoteWorkspaceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !remoteWorkspaceIDs.isEmpty else { return projections.first }
        for remoteWorkspaceID in remoteWorkspaceIDs {
            if let projection = projections.first(where: { $0.remoteWorkspaceID == remoteWorkspaceID }) {
                return projection
            }
        }
        return projections.first { $0.remoteWorkspaceID == nil }
    }

    /// Replays the session identity of Claude agents in `cmux ssh` panes into
    /// the local hook queue, so the Mac's hook pipeline knows the remote
    /// agent's session. Runs with every accepted state and every catalog
    /// change, so a session whose pane was not open yet is caught up when it
    /// opens. Sidebar status comes from the roster projection, and visible
    /// notifications from the daemon's durable rows (`syncNotifications`).
    func syncAgentHooks(from state: TuiState) {
        guard machine.isSSH else { return }
        let machine = self.machine
        let catalog = self.catalog
        func remoteWorkspaceIDs(for terminalID: String) -> [String] {
            Self.remoteWorkspaceIDs(showing: terminalID, in: state)
        }
        func panel(for terminalID: String) -> SurfaceProjection? {
            Self.mirroredAgentHookProjection(
                projections: catalog.projections(of: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)),
                remoteWorkspaceIDs: remoteWorkspaceIDs(for: terminalID)
            )
        }
        let routable = Set(state.agents.map(\.terminalID).filter { panel(for: $0) != nil })
        let events = agentHookMirror.reconcile(agents: state.agents, routableTerminalIDs: routable)
        guard !events.isEmpty else { return }
        let controller = TerminalController.shared
        for event in events {
            // A session end for a terminal whose pane already closed has no
            // local state left to clear.
            guard let projection = panel(for: event.terminalID) else { continue }
            let queued = controller.enqueueMirroredAgentHook(
                agent: event.agent,
                subcommand: event.subcommand,
                payload: event.payload,
                workspaceID: projection.workspaceID,
                surfaceID: projection.panelID
            )
            #if DEBUG
            cmuxDebugLog("SSH.agentHook.mirror machine=\(machineID) terminal=\(event.terminalID) subcommand=\(event.subcommand) queued=\(queued)")
            #else
            _ = queued
            #endif
        }
    }
    /// Placement from the catalog as it is right now; see
    /// `TuiNotificationPlacementResolver`.
    var notificationPlacementResolver: TuiNotificationPlacementResolver {
        TuiNotificationPlacementResolver(
            machine: machine,
            projections: { [catalog] in catalog.projections(of: $0) },
            remoteWorkspaceIDs: { [weak self] terminalID in
                guard let state = self?.tuiState else { return [] }
                return Self.remoteWorkspaceIDs(showing: terminalID, in: state)
            },
            boundWorkspaces: { [catalog, machineID] in
                catalog.tuiWorkspaceRenameService.environment.workspaces().compactMap { workspace in
                    guard let binding = workspace.remoteWorkspaceBinding, binding.machineID == machineID else { return nil }
                    return TuiNotificationBoundWorkspace(workspaceID: workspace.id, remoteWorkspaceID: binding.remoteWorkspaceID)
                }
            }
        )
    }
    func notificationDeliveryTarget(for row: TuiNotificationRow) -> TuiNotificationDeliveryTarget? {
        notificationPlacementResolver.target(for: row)
    }
    func deliverNotification(_ row: TuiNotificationRow, to target: TuiNotificationDeliveryTarget) -> TuiNotificationDeliveryOutcome {
        let machineID = self.machineID
        return TuiNotificationLocalDelivery(
            machineID: machineID,
            store: { AppDelegate.shared?.notificationStore },
            admit: { [catalog] in catalog.tuiNotificationSyncHub.admit($0, machineID: machineID) },
            machineName: { [summary] in summary.preferredName },
            terminalTitle: { [weak self] in self?.tuiState?.lookupIndex.terminal(id: $0)?.title }
        ).deliver(row, to: target)
    }
}
