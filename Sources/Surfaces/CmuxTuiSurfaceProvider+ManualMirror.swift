import CmuxRemoteSession
import CmuxTui
import CmuxSurfaceCatalogModel
import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    nonisolated static func shouldShowRecoverableTuiFailure(observation: TuiStateObservation) -> Bool {
        observation.freshness != .current
    }

    /// Creates a native manual-I/O pane and attaches it to the remote PTY.
    ///
    /// The legacy tree lookup is only an identity bridge: public `term_…`
    /// resource ids intentionally hide the numeric surface id used by the raw
    /// attach stream.
    func materializeManualMirrorTerminal(
        _ resource: SurfaceResource,
        remoteTabID: String? = nil,
        at destination: SurfaceDestination,
        focus: Bool,
        adopting reservation: TuiTerminalPaneReservation? = nil
    ) async throws -> TuiManualMirrorMaterialization {
        try catalog.validateOwnership(of: [resource.id], at: destination)
        let allowPlacementRepair = reservation?.attachmentPlacement.map { expected in
            remoteTabID == nil || remoteTabID == expected.remoteTabID
        } ?? false
        let savedPlacement = try reservation?.validatedAttachmentPlacement(
            resourceID: resource.id, remoteTabID: remoteTabID, catalog: catalog,
            allowPlacementRepair: allowPlacementRepair
        )
        let requiresExistingView = !allowPlacementRepair && (remoteTabID != nil || savedPlacement != nil)
        let preferredWorkspaceID = savedPlacement?.workspaceID
            ?? reservation?.attachmentPlacement?.remoteWorkspaceID
            ?? resource.remoteWorkspace?.id
            ?? catalog.tuiPlacementCoordinator.boundRemoteWorkspaceID(forLocalWorkspace: destination.workspaceID, on: machine)
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.connectionUnavailable(machineID)
        }
        let correlationID = UUID().uuidString.lowercased()
        try catalog.validateOwnership(of: [resource.id], at: destination)
        // A pool terminal opened into a mirrored workspace takes its tab there, not in
        // whichever workspace the daemon happens to focus.
        let resolved: (surfaceID: UInt64, placement: SurfaceRemotePlacement?)
        if resource.creationAttachment != nil {
            resolved = (0, nil)
        } else {
            resolved = try await resolveSurfaceIDForMaterialization(
                terminalID: resource.id.key,
                socketPath: connected.socketPath,
                link: link,
                requiresExistingView: requiresExistingView,
                correlationID: correlationID,
                // A newly-created terminal carries the workspace selected by the
                // creation request even before its first tab receipt arrives. Keep
                // that identity ahead of the local binding or daemon focus so a
                // missing tab_id cannot redirect projection to another workspace.
                preferredWorkspaceID: preferredWorkspaceID
            )
        }
        let knownPlacement = remoteTabID.flatMap { tabID in
            resource.remoteViews?.first(where: { $0.tabID == tabID })
                .map { SurfaceRemotePlacement(workspaceID: $0.workspace.id, tabID: $0.tabID) }
        }
        let confirmedPlacement = try reservation?.validatedAttachmentPlacement(
            resourceID: resource.id, remoteTabID: remoteTabID,
            materializedPlacement: resolved.placement, catalog: catalog,
            allowPlacementRepair: allowPlacementRepair
        ) ?? resolved.placement ?? knownPlacement
        if allowPlacementRepair, resource.creationAttachment == nil, confirmedPlacement == nil {
            // A restored pane without a confirmed replacement would attach to a
            // live numeric surface while losing its remote tab identity.
            throw TuiTransportError.placementMismatch
        }
        try TuiMachineLoadingReservation.current?.validate(materializedPlacement: confirmedPlacement)
        let session = TuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: resolved.surfaceID,
            creationAttachment: resource.creationAttachment,
            resolveLegacySurfaceID: { [weak self] in
                guard let self else { throw CancellationError() }
                let resolved = try await self.resolveSurfaceIDForMaterialization(
                    terminalID: resource.id.key, socketPath: connected.socketPath, link: link,
                    requiresExistingView: requiresExistingView, correlationID: correlationID,
                    preferredWorkspaceID: preferredWorkspaceID
                )
                return resolved.surfaceID
            },
            correlationID: correlationID,
            onNeedsReconnect: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        let inputRouter = session.inputRouter
        do {
            try catalog.validateOwnership(of: [resource.id], at: destination)
            let created: (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)
            if let reservation {
                // The user's pane already exists; bind the attachment to it. A pane
                // closed while the daemon created the terminal ends this request
                // without a replacement pane, like closing any pending pane.
                guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
                      let adopted = workspace.adoptReservedTuiTerminalPane(
                          reservation,
                          onResize: { [weak session] sample in session?.apply(size: sample) },
                          onRuntimeReady: { [weak session] in session?.runtimeReady() },
                          onFocus: { [weak session] in session?.claimGeometry() },
                          attachment: session.attachmentStatus
                      ) else {
                    throw CancellationError()
                }
                workspace.updateTuiTerminalTabIcon(
                    panelID: adopted.panelID,
                    assetName: resource.terminalAgentIconAssetName
                )
                created = adopted
                reservation.inputRelay.attach(inputRouter)
                // The card's grace counts from the moment the pane appeared.
                session.startPresentationEpisode(elapsed: reservation.elapsed)
            } else {
                created = try SurfacePaneFactory.makeTuiManualMirrorPane(
                    at: destination,
                    focus: focus,
                    iconAssetName: resource.terminalAgentIconAssetName,
                    onInput: { input in inputRouter.send(input) },
                    keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value },
                    onResize: { [weak session] sample in
                        session?.apply(size: sample)
                    },
                    onRuntimeReady: { [weak session] in
                        session?.runtimeReady()
                    },
                    onFocus: { [weak session] in
                        session?.claimGeometry()
                    },
                    attachment: session.attachmentStatus,
                    allowsRemoteClipboardWrites: sshClipboardWriteTrustStore
                        .allowsRemoteClipboardWrites(for: machine)
                )
            }
            session.bind(surface: created.surface)
            // Keep Cloud input convergence on the panel. Workspace transfer
            // rebinds the ordinary terminal callback, while this hook resolves
            // the panel's current owner after a move.
            if let createdPanel = Workspace.liveWorkspace(id: created.workspaceID)?.panels[created.panelID] as? TerminalPanel {
                Workspace.bindTuiManualMirrorInputConvergence(
                    panel: createdPanel,
                    isActive: { [weak session, weak createdPanel] in
                        guard let session, let createdPanel else { return false }
                        return session.phase != .stopped && session.surface === createdPanel.surface
                    },
                    onExplicitInput: { [weak session] in session?.noteExplicitInput() }
                )
            }
            manualMirrorSessions[created.panelID] = session
            session.reconnect(socketPath: connected.socketPath, handshake: reservation?.takeAttachHandshake())
            return TuiManualMirrorMaterialization(
                workspaceID: created.workspaceID,
                panelID: created.panelID,
                surface: created.surface,
                session: session,
                remotePlacement: confirmedPlacement
            )
        } catch {
            session.stop()
            throw error
        }
    }

    /// Registers a new pane's attach stream while the machine creates its
    /// terminal, so the attachment needs only `attach-surface` once the
    /// terminal exists. The link is the machine's existing one.
    func beginAttachHandshake(for reservation: TuiTerminalPaneReservation) {
        let handshake = TuiManualMirrorHandshake(identity: TuiManualMirrorSession.localSharingIdentity)
        reservation.beginAttachHandshake(handshake)
        let links = links
        let machineID = machineID
        // Only a link that is already up: connecting or resuming the machine
        // stays with the create, which owns its diagnostics and backoff.
        handshake.start {
            guard let link = await links.link(machineID: machineID),
                  await link.isConnected,
                  let connected = await link.connected else { throw CancellationError() }
            return connected.socketPath
        }
    }

    /// Resolves the daemon-local surface needed by a byte attachment.
    ///
    /// A live terminal with zero remote views resolves to `noPlacement`; one
    /// unfocused remote tab is projected before resolving again. A daemon that
    /// does not answer in time is retried on the bounded materialize schedule
    /// and then reported as "did not answer", never as "not created": the
    /// terminal keeps running on the machine either way.
    private func resolveSurfaceIDForMaterialization(
        terminalID: String,
        socketPath: String,
        link: RemoteMachineLink,
        requiresExistingView: Bool,
        correlationID: String,
        preferredWorkspaceID: String? = nil
    ) async throws -> (surfaceID: UInt64, placement: SurfaceRemotePlacement?) {
        let resolver = TuiTerminalAttachmentResolver(machineID: machineID, commandRunner: link, socketPath: socketPath, correlationID: correlationID)
        var failures = 0
        var lastReason = ""
        var lastFailure = TuiSurfaceIDResolution.Failure.notReady
        var projectedPlacement: SurfaceRemotePlacement?
        while true {
            try Task.checkCancellation()
            var resolution = await resolver.resolve(terminalID: terminalID)
            attachmentLog.resolution(machineID: machineID, terminalID: terminalID, attempt: failures + 1, outcome: resolution)
            if resolution == .noPlacement {
                guard !requiresExistingView else { throw ProviderError.terminalNotCreated(terminalID) }
                let projected = try await ensureRemoteTerminalView(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link,
                    preferredWorkspaceID: preferredWorkspaceID
                )
                projectedPlacement = projected
                attachmentLog.projection(machineID: machineID, terminalID: terminalID, placement: projected)
                resolution = await resolver.resolve(terminalID: terminalID)
                attachmentLog.resolution(machineID: machineID, terminalID: terminalID, attempt: failures + 1, outcome: resolution)
            }
            // Initial and post-projection answers share the same lifecycle/error handling.
            switch resolution {
            case let .resolved(surfaceID):
                return (surfaceID, projectedPlacement)
            case .exited:
                // The remote shell already ended, including during projection.
                throw ProviderError.terminalExited(terminalID)
            case .noPlacement:
                lastReason = "the projected view did not resolve"
                lastFailure = .notReady
            case let .retryable(reason, failure):
                lastReason = reason
                lastFailure = failure
            }
            failures += 1
            guard let delay = TuiTerminalAttachmentRetryPolicy.materialize.boundedDelay(afterFailures: failures) else {
                attachmentLog.giveUp(machineID: machineID, terminalID: terminalID, attempts: failures, reason: lastReason)
                throw ProviderError.terminalAttachTimedOut(terminalID: terminalID, failure: lastFailure)
            }
            try await attachmentClock.sleep(for: delay)
        }
    }

    /// Shares one in-flight remote projection among local panes opening the same pool
    /// terminal. Cancellation of an individual waiter does not cancel the shared mutation;
    /// the provider tears it down only when the machine/provider itself stops.
    private func ensureRemoteTerminalView(
        terminalID: String,
        socketPath: String,
        link: RemoteMachineLink,
        preferredWorkspaceID: String? = nil
    ) async throws -> SurfaceRemotePlacement {
        // Attachment needs one backing tab per terminal, irrespective of which local
        // pane opens first. Each accepted pane then submits its bound destination via
        // the catalog's shared placement lane.
        let key = socketPath + "\u{0}" + terminalID
        if let task = remoteTerminalProjectionTasks[key] { return try await task.value }
        let task = Task<SurfaceRemotePlacement, Error> { @MainActor [weak self] in
            guard let self else { throw ProviderError.terminalNotCreated(terminalID) }
            let snapshot = try await link.run(arguments: TuiRequests.snapshotArguments(socketPath: socketPath))
            guard let destination = await CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot, preferringWorkspace: preferredWorkspaceID) else {
                throw ProviderError.noWorkspaceOnMachine(self.machineID)
            }
            return try await self.ensureTerminalAttachment(
                SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID),
                preferringRemoteWorkspace: destination.target.workspaceID
            )
        }
        remoteTerminalProjectionTasks[key] = task
        defer { remoteTerminalProjectionTasks[key] = nil }
        return try await task.value
    }

    /// Refreshes attachment identities and repairs a backing placement that
    /// disappeared while a local pane stayed alive. A numeric surface id is
    /// never reused after a failed resolution; the session is first fenced,
    /// then a fresh remote projection is created and resolved once more.
    func resolveManualMirrorSessions(
        _ sessions: [TuiManualMirrorSession],
        socketPath: String,
        link: RemoteMachineLink
    ) async -> [String: TuiSurfaceIDResolution] {
        let resolver = TuiTerminalAttachmentResolver(machineID: machineID, commandRunner: link, socketPath: socketPath)
        let sessionsByTerminal = Dictionary(grouping: sessions, by: \.terminalID)
        var resolutions = await resolver.resolve(terminalIDs: Set(sessionsByTerminal.keys))
        let terminalsWithoutPlacement: Set<String> = Set(
            sessions.compactMap { session in
                guard resolutions[session.terminalID] == .noPlacement else { return nil }
                return session.terminalID
            }
        )
        for terminalID in terminalsWithoutPlacement {
            guard !Task.isCancelled else { break }
            if let state = tuiState {
                let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
                guard catalog.projections(of: resourceID).contains(where: {
                    catalog.tuiWorkspaceProjectionCoordinator.retainsProjection($0, in: state)
                }) else { continue }
            }
            for session in sessionsByTerminal[terminalID] ?? [] {
                session.markSurfaceResolutionUnavailable()
            }
            await catalog.tuiPlacementCoordinator.repairPlacement(
                for: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID),
                catalog: catalog
            ) { preferredWorkspaceID in
                try await self.ensureRemoteTerminalView(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link,
                    preferredWorkspaceID: preferredWorkspaceID
                )
            }
            resolutions[terminalID] = await resolver.resolve(terminalID: terminalID)
        }
        return resolutions
    }

    /// Attaches a reserved pane to `resource` and keeps trying until it works.
    ///
    /// Used for restored panes and for a Cloud workspace opened as a whole: the
    /// projection is already recorded on the reserved pane, so the layout is
    /// complete before any machine round trip, and every pane attaches in
    /// parallel. A failure is transient by default (the link is still coming up
    /// after a relaunch, the daemon's ordered lane is busy): the loop waits on
    /// the background backoff and tries again, and only after several rounds
    /// does the pane show Reconnect, which restarts the loop at once. Closing
    /// the pane cancels the loop; a terminal that exited is reported as such.
    func attachReservedTerminalPane(
        _ reservation: TuiTerminalPaneReservation,
        resource: SurfaceResource,
        remoteTabID: String?
    ) {
        let panelID = reservation.panelID
        materializedPanels.insert(panelID)
        restoredAttachTasks[panelID]?.cancel()
        let generation = lifecycleGeneration
        reservation.retry = { [weak self] in
            guard let self else { return }
            self.restoredAttachTasks[panelID]?.cancel()
            Workspace.liveWorkspace(id: reservation.workspaceID)?.restartReservedTuiTerminalPane(reservation)
            self.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: remoteTabID)
        }
        reservation.cancel = { [weak self] in
            guard let self else { return }
            self.restoredAttachTasks.removeValue(forKey: panelID)?.cancel()
            self.materializedPanels.remove(panelID)
        }
        if Self.shouldShowRecoverableTuiFailure(
            observation: catalog.tuiStateObservations[machine] ?? .stale(reason: "missing")
        ),
           let workspace = Workspace.liveWorkspace(id: reservation.workspaceID) {
            restoredAttachTasks[panelID] = nil
            materializedPanels.remove(panelID)
            workspace.failReservedTuiTerminalPane(
                reservation,
                error: TuiTransportError.connectionClosed
            )
            return
        }
        restoredAttachTasks[panelID] = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog(),
                      let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
                      workspace.tuiPendingCreations[panelID] === reservation else { return }
                let destination = SurfaceDestination.tab(
                    workspaceID: reservation.workspaceID,
                    paneID: SurfacePaneFactory.paneID(ofPanel: panelID, in: reservation.workspaceID) ?? "",
                    index: nil
                )
                do {
                    let materialized = try await self.materializeManualMirrorTerminal(
                        resource,
                        remoteTabID: remoteTabID,
                        at: destination,
                        focus: false,
                        adopting: reservation
                    )
                    guard !Task.isCancelled, self.isCurrentLifecycleGeneration(generation) else {
                        self.manualMirrorSessions.removeValue(forKey: materialized.panelID)?.stop()
                        return
                    }
                    do {
                        _ = try reservation.validatedAttachmentPlacement(
                            resourceID: resource.id, remoteTabID: remoteTabID,
                            materializedPlacement: materialized.remotePlacement, catalog: self.catalog,
                            allowPlacementRepair: reservation.attachmentPlacement.map { expected in
                                remoteTabID == nil || remoteTabID == expected.remoteTabID
                            } ?? false
                        )
                    } catch {
                        self.manualMirrorSessions.removeValue(forKey: materialized.panelID)?.stop()
                        reservation.inputRelay.discard()
                        throw error
                    }
                    if let placement = materialized.remotePlacement {
                        self.catalog.tuiPlacementCoordinator.confirmPlacement(placement, on: self.machine)
                        if let current = self.catalog.projection(forPanel: panelID) {
                            self.catalog.setRemotePlacement(for: current, placement: placement)
                        }
                    }
                    workspace.completeReservedTuiTerminalPane(reservation, adoptedPanelID: materialized.panelID)
                    self.restoredAttachTasks[panelID] = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if error as? TuiTransportError == .placementMismatch {
                        self.restoredAttachTasks[panelID] = nil
                        workspace.failReservedTuiTerminalPane(reservation, error: error)
                        return
                    }
                    if let providerError = error as? CmuxTuiSurfaceProvider.ProviderError,
                       case .terminalExited = providerError {
                        // The shell ended while the pane was waiting: the pane
                        // closes the way an exited local terminal does.
                        self.restoredAttachTasks[panelID] = nil
                        workspace.cancelReservedTuiTerminalPane(panelID: panelID)
                        SurfacePaneFactory.closeExited(panelID: panelID, in: reservation.workspaceID)
                        return
                    }
                    let inventoryIsStale = Self.shouldShowRecoverableTuiFailure(
                        observation: self.catalog.tuiStateObservations[self.machine] ?? .stale(reason: "missing")
                    )
                    if inventoryIsStale {
                        self.restoredAttachTasks[panelID] = nil
                        self.materializedPanels.remove(panelID)
                        workspace.failReservedTuiTerminalPane(reservation, error: error)
                        return
                    }
                    failures += 1
                    self.attachmentLog.giveUp(
                        machineID: self.machineID, terminalID: resource.id.key,
                        attempts: failures, reason: RemoteMachineLink.errorText(error)
                    )
                    if failures >= Self.reservedAttachFailuresBeforeReporting {
                        workspace.failReservedTuiTerminalPane(reservation, error: error)
                    }
                    let delay = TuiTerminalAttachmentRetryPolicy.background.cappedDelay(afterFailures: failures)
                    do { try await self.attachmentClock.sleep(for: delay) } catch { return }
                }
            }
        }
    }

    /// Rounds of the background backoff (1 s, 2 s, 4 s, 8 s: about fifteen
    /// seconds) a restored pane may fail before it explains itself with Reconnect.
    static let reservedAttachFailuresBeforeReporting = 4
}
