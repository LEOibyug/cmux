import CmuxSSHClipboardTrust
import CmuxRemoteSession
import CmuxTui
import CmuxCore
import CmuxSurfaceCatalogModel
import CmuxSettings
import Foundation
import os

private let sshTuiWorkspaceLogger = Logger(subsystem: "com.cmuxterm.app", category: "SSHTuiWorkspace")

/// Composes SSH carriers with the same terminal graph and native projections as Cloud.
@MainActor
final class SSHTuiWorkspaceCoordinator {
    private let catalog: SurfaceCatalog
    private let sshClipboardWriteTrustStore: SSHClipboardWriteTrustStore
    private let clientURL: () -> URL?
    private let paths: TuiClientPaths
    private var attempts: [UUID: Task<Void, Never>] = [:]
    private let agentStatus: SSHTuiAgentStatusProjector
    private let retryPolicy: SSHTuiAttachRetryPolicy
    private let clock: any Clock<Duration>
    /// Restored attaches that failed and are waiting to try again, either in
    /// a backoff wait or parked after reporting their error.
    private var recoveries: [UUID: Recovery] = [:]
    private var catalogObserver: NSObjectProtocol?

    private struct Recovery {
        weak var workspace: Workspace?
        let configuration: WorkspaceRemoteConfiguration
        let machine: SurfaceMachineID
        /// Cleared when the link is later seen down, so its next link-up retries.
        var linkWasConnectedAtFailure: Bool
        /// Set while the attach waits out a backoff; nil once it has parked.
        let backoff: SSHTuiAttachBackoff?
    }

    init(
        catalog: SurfaceCatalog,
        clientURL: @escaping () -> URL?,
        paths: TuiClientPaths,
        sshClipboardWriteTrustStore: SSHClipboardWriteTrustStore? = nil,
        retryPolicy: SSHTuiAttachRetryPolicy = .standard,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.catalog = catalog
        self.sshClipboardWriteTrustStore = sshClipboardWriteTrustStore ?? SSHClipboardWriteTrustStore(defaults: .standard)
        self.clientURL = clientURL
        self.paths = paths
        self.retryPolicy = retryPolicy
        self.clock = clock
        agentStatus = SSHTuiAgentStatusProjector(catalog: catalog)
        catalogObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification, object: catalog, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryRecoveriesWhoseLinkCameUp() }
        }
    }

    nonisolated static func usesDurableCreationReceipt(machineID: String, restoring: Bool) -> Bool {
        restoring && !machineID.hasPrefix("ssh:")
    }

    /// A fresh local SSH workspace has no remote projections to reconcile
    /// before its idempotent remote workspace create. Restores and workspaces
    /// that already carry SSH state still need the authoritative graph first.
    nonisolated static func needsInitialGraphRefresh(
        restoring: Bool,
        hasExistingProjections: Bool,
        hasRemoteBinding: Bool
    ) -> Bool {
        restoring || hasExistingProjections || hasRemoteBinding
    }


    /// Restores and reconnects an existing SSH workspace.
    ///
    /// The workspace stays `.connecting` while retryable failures back off,
    /// so a relaunch that races network startup does not flash SSH errors.
    func connect(workspace: Workspace, configuration: WorkspaceRemoteConfiguration) {
        for projection in catalog.projections where projection.workspaceID == workspace.id && projection.resource.machine.isSSH {
            let provider = catalog.provider(for: projection.resource.machine) as? CmuxTuiSurfaceProvider
            _ = provider?.manualMirrorSessions[projection.panelID]?.retryConnection()
        }
        startAttempt(workspace: workspace, configuration: configuration)
    }

    private func startAttempt(workspace: Workspace, configuration: WorkspaceRemoteConfiguration) {
        attempts.removeValue(forKey: workspace.id)?.cancel()
        recoveries.removeValue(forKey: workspace.id)
        let attemptID = UUID()
        workspace.sshTuiConnectionAttemptID = attemptID
        if workspace.remoteConnectionState != .connecting {
            workspace.applyRemoteConnectionStateUpdate(.connecting, detail: nil, target: configuration.displayTarget)
        }
        let machine = SurfaceMachineID.ssh(SSHTuiConnection(configuration: configuration).identityDigest)
        attempts[workspace.id] = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            defer {
                if workspace.sshTuiConnectionAttemptID == attemptID { self.attempts[workspace.id] = nil }
            }
            let backoff = SSHTuiAttachBackoff()
            let outcome = await SSHTuiAttachRetry.run(
                policy: self.retryPolicy,
                clock: self.clock,
                backoff: backoff,
                failed: { [weak self, weak workspace] error in
                    guard let self, let workspace, workspace.sshTuiConnectionAttemptID == attemptID else { return }
                    sshTuiWorkspaceLogger.info("restored SSH attach failed, retrying: \(RemoteMachineLink.errorText(error), privacy: .public)")
                    self.recoveries[workspace.id] = Recovery(
                        workspace: workspace, configuration: configuration, machine: machine,
                        linkWasConnectedAtFailure: self.catalog.machines[machine]?.linkState == .connected,
                        backoff: backoff
                    )
                },
                retrying: { [weak self, weak workspace] in
                    // A wait that ended takes no further wakes; a stale one
                    // would cut the next failure's backoff short.
                    guard let self, let workspace,
                          self.recoveries[workspace.id]?.backoff === backoff else { return }
                    self.recoveries.removeValue(forKey: workspace.id)
                },
                attempt: { willRetry in
                    try await self.attach(workspace: workspace, configuration: configuration, attemptID: attemptID,
                                          restoring: true, keepsReservationPending: willRetry)
                }
            )
            guard workspace.sshTuiConnectionAttemptID == attemptID else { return }
            switch outcome {
            case .connected:
                self.recoveries.removeValue(forKey: workspace.id)
            case .cancelled:
                // Still current, so nothing replaced this attempt: remote
                // connections were turned off. Do not leave it connecting.
                self.recoveries.removeValue(forKey: workspace.id)
                workspace.applyRemoteConnectionStateUpdate(.disconnected, detail: nil, target: configuration.displayTarget)
            case .failed(let error):
                workspace.applyRemoteConnectionStateUpdate(.error, detail: RemoteMachineLink.errorText(error), target: configuration.displayTarget)
                guard !SSHTuiAttachRetryPolicy.isPermanent(error) else {
                    // Park so a later link-up still recovers the workspace
                    // and retracts this error, without a manual Reconnect.
                    self.recoveries[workspace.id] = Recovery(
                        workspace: workspace, configuration: configuration, machine: machine,
                        linkWasConnectedAtFailure: self.catalog.machines[machine]?.linkState == .connected,
                        backoff: nil
                    )
                    return
                }
                await self.retryQuietlyAfterReportedFailure(workspace: workspace, configuration: configuration,
                                                            machine: machine, attemptID: attemptID)
            }
        }
    }

    /// Keeps a reported, retryable failure trying on a slow cadence while the
    /// workspace stays `.error`, so a host that comes back recovers and the
    /// error retracts without a manual Reconnect. A link-up ends each wait early.
    private func retryQuietlyAfterReportedFailure(workspace: Workspace, configuration: WorkspaceRemoteConfiguration,
                                                  machine: SurfaceMachineID, attemptID: UUID) async {
        while !Task.isCancelled, workspace.sshTuiConnectionAttemptID == attemptID {
            let backoff = SSHTuiAttachBackoff()
            recoveries[workspace.id] = Recovery(
                workspace: workspace, configuration: configuration, machine: machine,
                linkWasConnectedAtFailure: catalog.machines[machine]?.linkState == .connected,
                backoff: backoff
            )
            await backoff.wait(retryPolicy.reportedFailureRetryInterval, clock: clock)
            guard !Task.isCancelled, workspace.sshTuiConnectionAttemptID == attemptID else { return }
            if recoveries[workspace.id]?.backoff === backoff { recoveries.removeValue(forKey: workspace.id) }
            do {
                try await attach(workspace: workspace, configuration: configuration, attemptID: attemptID, restoring: true)
                return
            } catch {
                guard workspace.sshTuiConnectionAttemptID == attemptID, !(error is CancellationError) else { return }
                if SSHTuiAttachRetryPolicy.isPermanent(error) {
                    workspace.applyRemoteConnectionStateUpdate(.error, detail: RemoteMachineLink.errorText(error), target: configuration.displayTarget)
                    return
                }
            }
        }
    }

    /// The provider's terminal mirrors reconnect the carrier on their own.
    /// When that brings the machine link up, a waiting or parked restore
    /// attach retries at once so the workspace reports connected promptly.
    private func retryRecoveriesWhoseLinkCameUp() {
        guard !recoveries.isEmpty else { return }
        for (workspaceID, recovery) in recoveries {
            let linkState = catalog.machines[recovery.machine]?.linkState
            guard SSHTuiAttachRetryPolicy.shouldRetryNow(
                linkWasConnectedAtFailure: recovery.linkWasConnectedAtFailure,
                linkState: linkState
            ) else {
                if linkState != .connected, recovery.linkWasConnectedAtFailure {
                    recoveries[workspaceID]?.linkWasConnectedAtFailure = false
                }
                continue
            }
            if let backoff = recovery.backoff {
                // One early retry per failure; the next failure records a fresh link state.
                recoveries.removeValue(forKey: workspaceID)
                backoff.wake()
            } else {
                recoveries.removeValue(forKey: workspaceID)
                guard let workspace = recovery.workspace, !workspace.isRetiredFromOwningTabManager,
                      workspace.remoteConfiguration.map({ SSHTuiConnection(configuration: $0).id }) == recovery.machine.rawValue
                else { continue }
                startAttempt(workspace: workspace, configuration: recovery.configuration)
            }
        }
    }

    func provider(connection: SSHTuiConnection) throws -> CmuxTuiSurfaceProvider {
        let machine = SurfaceMachineID.ssh(connection.identityDigest)
        if let existing = catalog.provider(for: machine) as? CmuxTuiSurfaceProvider { return existing }
        guard let clientURL = clientURL() else { throw RemoteMachineLink.LinkError.clientMissing }
        let links = SSHTuiLinkManager(connection: connection, clientURL: clientURL, paths: paths,
                                     isEnabled: { ManagedRemoteConnectionsPolicy().isEnabled },
                                     agentHookProviders: { SSHTuiConnection.agentHookProviders(defaults: .standard) })
        let provider = CmuxTuiSurfaceProvider(
            summary: .ssh(connection), links: links, catalog: catalog,
            sshClipboardWriteTrustStore: sshClipboardWriteTrustStore
        )
        catalog.register(provider)
        return provider
    }

    func open(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, initialCommand: [String]? = nil, focus: Bool = true) async throws {
        attempts.removeValue(forKey: workspace.id)?.cancel()
        recoveries.removeValue(forKey: workspace.id)
        let attemptID = UUID()
        workspace.sshTuiConnectionAttemptID = attemptID
        let restoring = workspace.remoteConfiguration != nil
        workspace.remoteConfiguration = configuration
        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: nil, target: configuration.displayTarget)
        try await attach(workspace: workspace, configuration: configuration, attemptID: attemptID, initialCommand: initialCommand, restoring: restoring, focus: focus)
    }

    /// `keepsReservationPending` names the errors the caller will retry, so a
    /// reserved pane stays pending between attempts instead of failing.
    private func attach(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, attemptID: UUID, initialCommand: [String]? = nil, restoring: Bool = false, focus: Bool = false,
                        keepsReservationPending: (Error) -> Bool = { _ in false }) async throws {
        let held = ReservationHold()
        do {
            try await attachBody(workspace: workspace, configuration: configuration, attemptID: attemptID,
                                 initialCommand: initialCommand, restoring: restoring, focus: focus, held: held)
        } catch {
            if workspace.sshTuiConnectionAttemptID == attemptID, let reservation = held.reservation, !keepsReservationPending(error) {
                workspace.failReservedTuiTerminalPane(reservation, error: TuiTransportError.connectionClosed)
            }
            throw error
        }
    }

    /// The pane an attach reserved and has not yet handed to a projection.
    private final class ReservationHold {
        var reservation: TuiTerminalPaneReservation?
    }

    private func attachBody(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, attemptID: UUID, initialCommand: [String]?,
                            restoring: Bool, focus: Bool, held: ReservationHold) async throws {
        let connection = SSHTuiConnection(configuration: configuration)
        let provider = try provider(connection: connection)
        let machine = provider.machine
        held.reservation = reserveInitialTerminal(workspace: workspace, machine: machine, configuration: configuration, focus: focus)
        if let saved = configuration.restoredSSHSession, saved.sshSessionOwner != "cmux-tui" {
            // Use the same eligibility check as snapshot conversion, including
            // the legacy default when terminalTransport was not persisted.
            guard saved.legacyTmuxSSHConfiguration(agentSocketPath: configuration.agentSocketPath) != nil else {
                throw TuiTransportError.unsupported
            }
        }
        // A restored workspace already has projections, so it does not reach
        // the new-workspace creation branch below. Recover the replaceable SSH
        // sidecar before refreshing that existing graph, otherwise every pane
        // waits on the stale carrier left by the previous app process.
        if restoring, let sshLinks = provider.links as? SSHTuiLinkManager {
            _ = try await sshLinks.connected(machineID: connection.id, preflight: false)
        }
        let initialExisting = catalog.projections.filter {
            $0.workspaceID == workspace.id && $0.resource.machine == machine
        }
        let hasRemoteBinding = workspace.remoteWorkspaceBinding?.machineID == connection.id
        if Self.needsInitialGraphRefresh(
            restoring: restoring,
            hasExistingProjections: !initialExisting.isEmpty,
            hasRemoteBinding: hasRemoteBinding
        ) {
            guard await provider.refreshCurrentGraphResolvingEqualCursorConflict() else {
                throw RemoteMachineLink.LinkError.failureMessage(provider.info.linkFailureMessage)
            }
        }
        try requireCurrent(workspace: workspace, attemptID: attemptID)
        if !configuration.preserveAfterTerminalExit {
            workspace.applyRemoteConnectionStateUpdate(.connected, detail: nil, target: configuration.displayTarget)
            return
        }
        let existing = catalog.projections.filter { $0.workspaceID == workspace.id && $0.resource.machine == machine }
        if !existing.isEmpty {
            provider.projectionsRestored()
        } else if let binding = workspace.remoteWorkspaceBinding,
                  binding.machineID == connection.id,
                  let remoteID = binding.remoteWorkspaceID {
            // A missing saved terminal is never permission to create another shell.
            let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: remoteID)
            for placement in group.placements {
                let result = try await catalog.project(placement.resource, into: .workspace(id: workspace.id, placement: .tab),
                                                       focus: false, adopting: held.reservation)
                try requireCurrent(workspace: workspace, attemptID: attemptID)
                if let pending = held.reservation {
                    workspace.completeReservedTuiTerminalPane(pending, adoptedPanelID: result.projection.panelID)
                    held.reservation = nil
                }
            }
        } else {
            // A saved cmux-tui owner may only reattach its persisted workspace.
            if configuration.restoredSSHSession?.sshSessionOwner == "cmux-tui" {
                throw CmuxTuiSurfaceProvider.ProviderError.stateUnavailable(connection.id)
            }
            let connected: RemoteMachineLink.Connected
            if let sshLinks = provider.links as? SSHTuiLinkManager {
                connected = try await sshLinks.connected(machineID: connection.id, preflight: false)
            } else {
                connected = try await provider.links.connected(machineID: connection.id)
            }
            guard let link = await provider.links.link(machineID: connection.id) else { throw CancellationError() }
            let request = Self.remoteWorkspaceCreationRequest(for: workspace, socketPath: connected.socketPath)
            let response = try await link.run(arguments: request)
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let remoteID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
                throw CmuxTuiSurfaceProvider.ProviderError.invalidSnapshot(connection.id)
            }
            let resource = try await provider.createTerminal(
                command: initialCommand ?? connection.shellCommand, cwd: nil, name: nil, remoteWorkspaceID: remoteID,
                request: TuiTerminalCreationRequest(
                    id: workspace.stableId,
                    remoteWorkspaceID: remoteID,
                    restoring: Self.usesDurableCreationReceipt(machineID: connection.id, restoring: restoring)
                )
            )
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            if let title = Self.remoteWorkspaceTitleToPublish(for: workspace) {
                // A failed publish degrades to the daemon default name; log it rather than fail the attach.
                catalog.enqueueRemoteWorkspaceRename(on: machine, id: remoteID, name: title) { error in
                    sshTuiWorkspaceLogger.error("publishing the workspace title to \(remoteID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: connection.id, remoteWorkspaceID: remoteID)
            let projected = try await catalog.project(resource.id, into: .workspace(id: workspace.id, placement: .tab),
                                                      focus: false, adopting: held.reservation)
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            if let reservation = held.reservation {
                workspace.completeReservedTuiTerminalPane(reservation, adoptedPanelID: projected.projection.panelID)
                held.reservation = nil
            }
        }
        workspace.applyRemoteConnectionStateUpdate(.connected, detail: nil, target: configuration.displayTarget)
    }

    /// The `workspace.create` request an SSH attach sends when the workspace has no remote identity yet.
    ///
    /// It stays unnamed so its creation fingerprint is stable: the idempotency
    /// key is per workspace, and the daemon rejects a replay whose parameters
    /// changed (`creation.conflict`), which a title edit between retries would cause.
    static func remoteWorkspaceCreationRequest(for workspace: Workspace, socketPath: String) -> TuiRequest {
        TuiRequests.createWorkspaceArguments(socketPath: socketPath, empty: true)
            .withIdempotencyKey("ssh-workspace-" + workspace.stableId.uuidString.lowercased())
    }

    /// The local title an SSH attach publishes to the remote workspace it just created.
    ///
    /// Once the workspace is bound, the daemon graph owns its name and
    /// reconciliation projects that name onto the local title, so a title from
    /// `--name` or a restored snapshot must reach the daemon first. Attach
    /// enqueues it as a rename before binding; the pending rename keeps
    /// reconciliation from painting the daemon default (`workspace-N`) meanwhile.
    /// Auto titles are derived locally and are not pinned into the daemon, and a
    /// title over the daemon's 1024-byte workspace-name limit is not sent.
    static func remoteWorkspaceTitleToPublish(for workspace: Workspace) -> String? {
        guard workspace.effectiveCustomTitleSource != .auto,
              let title = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.utf8.count <= 1024 else { return nil }
        return title
    }

    /// Replace the local scaffold before yielding so an SSH workspace can never start a local shell.
    private func reserveInitialTerminal(workspace: Workspace, machine: SurfaceMachineID,
                                        configuration: WorkspaceRemoteConfiguration, focus: Bool = false) -> TuiTerminalPaneReservation? {
        guard configuration.preserveAfterTerminalExit else { return nil }
        if let pending = workspace.tuiPendingCreations.values.first(where: { $0.machine == machine }) {
            workspace.restartReservedTuiTerminalPane(pending)
            return pending
        }
        guard workspace.remoteWorkspaceBinding == nil,
              !catalog.projections.contains(where: { $0.workspaceID == workspace.id && $0.resource.machine == machine }) else { return nil }
        let scaffold = Set(workspace.panels.keys)
        guard let reservation = workspace.reserveTuiTerminalPane(
            machine: machine, at: .workspace(id: workspace.id, placement: .tab), focus: focus
        ) else { return nil }
        reservation.retry = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.connect(workspace: workspace, configuration: configuration)
        }
        for panelID in scaffold { SurfacePaneFactory.close(panelID: panelID, in: workspace.id) }
        return reservation
    }

    private func requireCurrent(workspace: Workspace, attemptID: UUID) throws {
        try Task.checkCancellation()
        guard workspace.sshTuiConnectionAttemptID == attemptID, !workspace.isRetiredFromOwningTabManager,
              ManagedRemoteConnectionsPolicy().isEnabled else { throw CancellationError() }
    }

    func disconnect(workspace: Workspace) {
        workspace.sshTuiConnectionAttemptID = nil
        attempts.removeValue(forKey: workspace.id)?.cancel()
        if recoveries.removeValue(forKey: workspace.id)?.backoff != nil {
            // A backoff keeps the reserved pane pending for the next attempt.
            // No attempt follows a disconnect, so show its failure card instead.
            for pending in workspace.tuiPendingCreations.values where pending.machine.isSSH {
                workspace.failReservedTuiTerminalPane(pending, error: TuiTransportError.connectionClosed)
            }
        }
        for projection in catalog.projections where projection.workspaceID == workspace.id && projection.resource.machine.isSSH {
            let provider = catalog.provider(for: projection.resource.machine) as? CmuxTuiSurfaceProvider
            _ = provider?.manualMirrorSessions[projection.panelID]?.cancelConnectionAttempt()
            if !ManagedRemoteConnectionsPolicy().isEnabled, let manager = provider?.links as? SSHTuiLinkManager {
                Task { await manager.disconnect() }
            }
        }
    }
}
