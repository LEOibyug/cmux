import CmuxRemoteSession
import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import CmuxWorkspaces
import Foundation

/// Cmd+D / Cmd+T from a pane that projects a cloud resource create the new terminal ON
/// that machine — in the same cmux-tui workspace — instead of a local shell. Same rule
/// as the remote tmux mirror: a "split" next to a remote pane means "another terminal
/// where that pane lives". The new terminal is created through the machine's provider
/// (`workspace <ws> run`) and projected back into this workspace at the requested spot,
/// so the sidebar, the socket, and the shortcut agree on what exists.
///
/// Every route is optimistic: the pane is reserved at the requested spot first
/// (`Workspace+CloudTerminalReservation`), the machine creates the terminal behind it,
/// and the attachment adopts the pane when it resolves. Nothing "starting" is ever shown
/// as a separate surface; a slow create shows the pane's own connecting card after the
/// same grace a reconnect uses, and a failure is explained inside the pane with Retry.
@MainActor
extension Workspace {
    /// The pane that initiated the request owns its error, regardless of later
    /// focus changes. A hidden source tab must not cover the tab replacing it.
    var tuiPaneCreationFailureSourceView: NSView? {
        guard let panelID = tuiPaneCreationFailureStore.failure?.sourcePanelID,
              let paneID = paneId(forPanelId: panelID),
              let surfaceID = surfaceIdFromPanelId(panelID),
              bonsplitController.selectedTab(inPane: paneID)?.id == surfaceID else { return nil }
        if let terminal = panels[panelID] as? TerminalPanel { return terminal.hostedView }
        if let browser = panels[panelID] as? BrowserPanel { return browser.webView }
        return nil
    }


    /// The cloud resource behind a panel, when the panel projects one.
    func tuiProjectedResource(forPanel panelID: UUID, catalog: SurfaceCatalog? = nil) -> SurfaceResource? {
        let catalog = catalog ?? SurfaceCatalog.shared
        guard let projection = catalog.projection(forPanel: panelID),
              projection.workspaceID == id,
              !projection.resource.machine.isLocal else { return nil }
        return catalog.resource(forPanel: panelID)
    }

    /// Captures ownership and exact placement in one MainActor turn, including
    /// panes whose create has not returned its catalog projection yet.
    func tuiTerminalSourcePlacement(forPanel panelID: UUID) -> TuiTerminalSourcePlacement? {
        guard panels[panelID] != nil else { return nil }
        let catalog = SurfaceCatalog.shared
        if let projection = catalog.projectionIncludingPendingRestore(forPanel: panelID),
           !projection.resource.machine.isLocal {
            guard projection.workspaceID == id else { return nil }
            let resource = catalog.resources[projection.resource]
            let remoteWorkspaceID = projection.remoteWorkspaceID ?? resource.flatMap {
                catalog.tuiPlacementCoordinator.creationWorkspaceID(in: id, near: $0)
            }
            return TuiTerminalSourcePlacement(
                machine: projection.resource.machine, resource: resource,
                remoteWorkspaceID: remoteWorkspaceID, remoteTabID: projection.remoteTabID
            )
        }
        if let reservation = tuiPendingCreations[panelID] {
            return TuiTerminalSourcePlacement(
                machine: reservation.machine, remoteWorkspaceID: reservation.remoteWorkspaceID,
                pendingCreation: reservation.creationReceipt
            )
        }
        // A disconnected provider may remove its graph while the native remote
        // transport remains. Absence of graph metadata is not local ownership.
        if let machineID = (panels[panelID] as? TerminalPanel)?.remoteAttachment?.machineID,
           let machine = SurfaceMachineID(rawValue: machineID) {
            return TuiTerminalSourcePlacement(machine: machine)
        }
        // Legacy managed-Cloud SSH and transferred panels can be Cloud-owned
        // without a catalog projection or manual-mirror attachment. Reuse the
        // same owner resolver used by drag rejection; if its workspace binding
        // is missing, the create route fails closed instead of repairing locally.
        if let machine = machineOwningSurface(panelID), !machine.isLocal {
            let remoteWorkspaceID = remoteWorkspaceBinding?.machineID == machine.tuiMachineID
                ? remoteWorkspaceBinding?.remoteWorkspaceID
                : nil
            return TuiTerminalSourcePlacement(
                machine: machine,
                remoteWorkspaceID: remoteWorkspaceID
            )
        }
        return nil
    }

    func rejectTuiTerminalCreation(source: TuiTerminalSourcePlacement, panelID: UUID) -> TerminalPanelCreationOutcome {
        presentTuiPaneCreationFailure(
            machine: source.machine, error: TuiTransportError.unsupported,
            requestID: tuiPaneCreationFailureStore.beginRequest(), sourcePanelID: panelID
        )
        return .failed
    }

    /// The cloud resource behind the selected tab of a pane (the Cmd+T anchor).
    func tuiProjectedResource(inPane paneID: PaneID) -> SurfaceResource? {
        guard let selectedTabID = bonsplitController.selectedTab(inPane: paneID)?.id,
              let panelID = panelIdFromSurfaceId(selectedTabID) else { return nil }
        return tuiProjectedResource(forPanel: panelID)
    }

    /// Routes a Cmd+D-style split from a cloud-projected panel to its machine.
    /// False means no request was accepted. The caller checks Cloud ownership first
    /// and returns a failure without entering its local-creation path.
    func routeTuiPaneTerminalSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool {
        guard let source = tuiTerminalSourcePlacement(forPanel: panelID),
              let paneID = paneId(forPanelId: panelID) else { return false }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right)
            : (insertFirst ? .up : .down)
        return routeTuiPaneTerminalCreate(
            source: source, sourcePanelID: panelID,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            focus: focus
        ).isAccepted
    }

    /// Routes a bonsplit UI split (the pane-divider split button) whose source pane
    /// projects a cloud resource: the already-created empty pane receives the machine's
    /// new terminal as its first tab. Returns false when the source is not cloud-anchored.
    func routeTuiPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID, orientation: SplitOrientation) -> Bool {
        guard let source = tuiTerminalSourcePlacement(forPanel: sourcePanelID) else { return false }
        let routed = routeTuiPaneTerminalCreate(
            source: source, sourcePanelID: sourcePanelID,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            focus: true,
            splitDirection: orientation == .horizontal ? .right : .down,
            pendingPane: newPane
        )
        if !routed.isAccepted { closeUntouchedPane(newPane) }
        return true
    }

    /// Routes a Cmd+T-style new tab in a pane whose selected tab projects a cloud
    /// resource to that machine. False reports rejection; the caller's prior Cloud
    /// ownership check prevents a rejected request from entering local creation.
    func routeTuiPaneTerminalTab(inPane paneID: PaneID, focus: Bool) -> Bool {
        guard let selectedTab = bonsplitController.selectedTab(inPane: paneID),
              let selectedPanelID = panelIdFromSurfaceId(selectedTab.id),
              let source = tuiTerminalSourcePlacement(forPanel: selectedPanelID) else { return false }
        return routeTuiPaneTerminalCreate(
            source: source, sourcePanelID: selectedPanelID,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            focus: focus
        ).isAccepted
    }

    /// Creates a terminal using the captured source placement and projects it at `destination`.
    /// The pane appears at once; the machine reports the terminal into it. A failure
    /// is shown in that pane instead of silently doing nothing, because the user's
    /// gesture otherwise looks dead.
    func routeTuiPaneTerminalCreate(
        source: TuiTerminalSourcePlacement,
        sourcePanelID: UUID?,
        destination: SurfaceDestination,
        focus: Bool,
        splitDirection: SurfaceSplitDirection? = nil,
        pendingPane: PaneID? = nil,
        commandOverride: [String]? = nil
    ) -> TerminalPanelCreationOutcome {
        let catalog = SurfaceCatalog.shared
        let machine = source.machine
        let requestID = tuiPaneCreationFailureStore.beginRequest()
        guard let provider = catalog.provider(for: machine) else {
            presentTuiPaneCreationFailure(machine: machine, error: SurfaceCatalogError.noProvider(machine),
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            return .failed
        }
        guard source.remoteWorkspaceID != nil || source.pendingCreation != nil else {
            presentTuiPaneCreationFailure(machine: machine, error: TuiTransportError.placementMismatch,
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            return .failed
        }
        if let remoteWorkspaceID = source.remoteWorkspaceID,
           catalog.isTuiWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
            presentTuiPaneCreationFailure(machine: machine, error: TuiTransportError.placementMismatch,
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return .routedToRemote
        }
        let effectiveCommand = commandOverride ?? (machine.isSSH ? remoteConfiguration.map { SSHTuiConnection(configuration: $0).shellCommand } : nil)
        let request = TuiTerminalCreationRequest(id: requestID, remoteWorkspaceID: source.remoteWorkspaceID, commandOverride: effectiveCommand)
        let reservationDestination: SurfaceDestination = pendingPane.map {
            .tab(workspaceID: id, paneID: $0.id.uuidString, index: nil)
        } ?? destination
        guard let reservation = reserveTuiTerminalPane(
            machine: machine,
            at: reservationDestination,
            focus: focus,
            sourcePlacement: source,
            requestID: requestID
        ) else {
            // The pane may have been closed or claimed while Bonsplit was
            // delivering the split callback. Remove only an untouched pane;
            // never leave a handled Cloud request as a blank slot.
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return .routedToRemote
        }

        #if DEBUG
        cmuxDebugLog("cloud.split.reserved request=\(requestID.uuidString.prefix(8)) panel=\(reservation.panelID.uuidString.prefix(8)) layout=\(source.remoteTabID != nil ? 1 : 0)")
        #endif
        var token: UUID?
        let beginProjectionMutation: @MainActor () -> Void = {
            if token == nil { token = catalog.tuiWorkspaceProjectionCoordinator.beginLocalMutation(on: machine) }
        }
        let endProjectionMutation: @MainActor () -> Void = {
            guard let current = token else { return }
            token = nil
            catalog.tuiWorkspaceProjectionCoordinator.endLocalMutation(current, on: machine, catalog: catalog)
        }
        let create: TuiTerminalCreationCoordinator.Create = {
            do {
                let resolvedSource = try await source.resolved()
                guard let resolvedWorkspaceID = resolvedSource.remoteWorkspaceID,
                      !resolvedWorkspaceID.isEmpty else { throw TuiTransportError.placementMismatch }
                request.bind(remoteWorkspaceID: resolvedWorkspaceID)
                guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                try catalog.checkTuiWorkspaceNavigation(machine: machine, workspaceID: resolvedWorkspaceID)
                let created: SurfaceResource
                if let sourceTabID = resolvedSource.remoteTabID,
                   let layoutProvider = provider as? any SurfaceLayoutTerminalCreating {
                    let direction: SurfaceSplitDirection?
                    if case .split(_, _, let requested) = destination { direction = requested }
                    else { direction = splitDirection }
                    created = try await layoutProvider.createTerminal(
                        nearTabID: sourceTabID, splitDirection: direction, request: request
                    )
                } else {
                    let workingDirectory: String?
                    if let resource = resolvedSource.resource { workingDirectory = await provider.currentWorkingDirectory(of: resource) }
                    else { workingDirectory = nil }
                    guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                    try catalog.checkTuiWorkspaceNavigation(machine: machine, workspaceID: resolvedWorkspaceID)
                    created = try await provider.createTerminal(
                        command: nil, cwd: workingDirectory, name: nil,
                        remoteWorkspaceID: resolvedWorkspaceID, request: request
                    )
                }
                guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                try resolvedSource.validate(created: created)
                #if DEBUG
                cmuxDebugLog("cloud.split.created request=\(requestID.uuidString.prefix(8)) terminal=\(created.id.key) attachment=\(created.creationAttachment != nil ? 1 : 0)")
                #endif
                return created
            } catch {
                endProjectionMutation()
                throw error
            }
        }
        runOptimisticTuiTerminalCreation(
            reservation: reservation,
            requestID: requestID,
            destination: destination,
            create: create,
            onStart: beginProjectionMutation,
            onFinish: endProjectionMutation
        )
        return terminalPanel(for: reservation.panelID).map(TerminalPanelCreationOutcome.created) ?? .routedToRemote
    }

    /// Starts a fresh terminal on `machine` (in `remoteWorkspaceID` when given) as a
    /// tab of this workspace's focused pane, optimistically. The Cloud sidebar's
    /// "New Terminal" and an empty remote workspace's open both land here, so they
    /// share the shortcut routes' pane, retry, and failure behavior. Returns false
    /// when the machine has no provider or the pane cannot be reserved.
    @discardableResult
    func openTuiTerminalOptimistically(on machine: SurfaceMachineID, remoteWorkspaceID: String?) -> Bool {
        let catalog = SurfaceCatalog.shared
        guard !machine.isLocal, let provider = catalog.provider(for: machine) else { return false }
        if let remoteWorkspaceID,
           catalog.isTuiWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
            // This was a handled Cloud action, but its target disappeared while
            // the row was still visible. Do not fall through to the awaited
            // fallback, which could create a terminal for the deleted workspace.
            return true
        }
        let requestID = tuiPaneCreationFailureStore.beginRequest()
        let destination = SurfaceDestination.workspace(id: id, placement: .tab)
        guard let reservation = reserveTuiTerminalPane(
            machine: machine, at: destination, focus: true,
            sourcePlacement: TuiTerminalSourcePlacement(machine: machine, remoteWorkspaceID: remoteWorkspaceID),
            requestID: requestID
        ) else { return false }
        let request = TuiTerminalCreationRequest(id: requestID)
        var token: UUID?
        let beginLocalMutation: @MainActor () -> Void = {
            if token == nil { token = catalog.tuiWorkspaceProjectionCoordinator.beginLocalMutation(on: machine) }
        }
        let endLocalMutation: @MainActor () -> Void = {
            guard let current = token else { return }
            token = nil
            catalog.tuiWorkspaceProjectionCoordinator.endLocalMutation(current, on: machine, catalog: catalog)
        }
        let create: TuiTerminalCreationCoordinator.Create = {
            do {
                if let remoteWorkspaceID {
                    if catalog.isTuiWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
                        self.discardReservedTuiTerminalPane(reservation)
                        throw CancellationError()
                    }
                    try catalog.checkTuiWorkspaceNavigation(machine: machine, workspaceID: remoteWorkspaceID)
                }
                return try await provider.createTerminal(
                    command: nil, cwd: nil, name: nil,
                    remoteWorkspaceID: remoteWorkspaceID,
                    request: request
                )
            } catch {
                endLocalMutation()
                throw error
            }
        }
        runOptimisticTuiTerminalCreation(
            reservation: reservation,
            requestID: requestID,
            destination: destination,
            create: create,
            onStart: beginLocalMutation,
            onFinish: endLocalMutation
        )
        return true
    }

    /// The shared coordinator run behind every optimistic route: one request id,
    /// one remote create, projection adopting the reserved pane, and pane-local
    /// failure and retry. `onStart`/`onFinish` bracket the projection-suppression
    /// scope the caller chose.
    func runOptimisticTuiTerminalCreation(
        reservation: TuiTerminalPaneReservation,
        requestID: UUID,
        destination: SurfaceDestination,
        create: @escaping TuiTerminalCreationCoordinator.Create,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        let catalog = SurfaceCatalog.shared
        let store = tuiPaneCreationFailureStore
        let project: TuiTerminalCreationCoordinator.Project = { [weak self, reservation] created in
            guard let self, !self.isRetiredFromOwningTabManager,
                  self.tuiPendingCreations[reservation.panelID] === reservation else {
                onFinish()
                throw CancellationError()
            }
            defer { onFinish() }
            // The stable terminal id is available before surface attachment.
            // Route reservation input into that PTY immediately so remote shell
            // startup owns echo and line discipline just like a local shell.
            if let tuiProvider = catalog.provider(for: created.machine) as? CmuxTuiSurfaceProvider {
                _ = try await tuiProvider.bindOptimisticTerminalInput(
                    reservation.inputRelay,
                    terminalID: created.id.key
                )
            }
            let remoteView = try reservation.sourcePlacement.remoteView(of: created)
            // The device layout can mirror the terminal here before its receipt
            // binds this reservation: a layout event that beats the create
            // response, or a retry after the first receipt was lost. A second
            // pane for the same terminal would leave that layout unable to
            // apply, so the reserved pane gives way to the mirrored one.
            if let existing = catalog.projections.first(where: {
                $0.workspaceID == self.id && $0.resource == created.id
                    && (remoteView == nil || $0.remoteTabID == remoteView?.tabID)
                    && self.panels[$0.panelID] != nil
            }) {
                self.completeReservedTuiTerminalPane(reservation, adoptedPanelID: existing.panelID)
                return (existing, true)
            }
            #if DEBUG
            cmuxDebugLog("cloud.split.project terminal=\(created.id.key)")
            #endif
            // Focus was granted when the pane appeared; adoption must not steal it
            // back from wherever the user has typed since.
            let result = try await catalog.project(
                    created.id,
                    into: destination,
                    focus: false,
                    reuseExisting: false,
                    remoteView: remoteView,
                    adopting: reservation
                )
            self.completeReservedTuiTerminalPane(reservation, adoptedPanelID: result.projection.panelID)
            #if DEBUG
            cmuxDebugLog("cloud.split.projected terminal=\(created.id.key)")
            #endif
            return result
        }
        reservation.retry = { [weak store] in store?.retry(requestID: requestID) }
        reservation.cancel = { [weak store] in store?.cancel(requestID: requestID) }
        store.run(
            machine: reservation.machine,
            requestID: requestID,
            create: {
                do {
                    let created = try await create()
                    try Task.checkCancellation()
                    try reservation.sourcePlacement.validate(created: created)
                    reservation.creationReceipt.finish(.success(created))
                    return created
                } catch {
                    let failure: Error = error is CancellationError ? TuiTransportError.placementMismatch : error
                    reservation.creationReceipt.finish(.failure(failure))
                    throw error
                }
            },
            project: project,
            onStart: { [weak self, reservation] in
                reservation.creationReceipt.beginAttempt()
                onStart()
                self?.restartReservedTuiTerminalPane(reservation)
                (catalog.provider(for: reservation.machine) as? CmuxTuiSurfaceProvider)?
                    .beginAttachHandshake(for: reservation)
            },
            onFinish: onFinish,
            inlineFailure: { [weak self, reservation] error in
                self?.failReservedTuiTerminalPane(reservation, error: error)
            },
            discardProjection: { projection in
                catalog.endProjections(panelID: projection.panelID, reason: .replaced)
            }
        )
    }

    /// Removes a pane a split created that never received a tab.
    private func closeUntouchedPane(_ pane: PaneID) {
        guard bonsplitController.allPaneIds.contains(pane),
              bonsplitController.tabs(inPane: pane).isEmpty else { return }
        _ = bonsplitController.closePane(pane)
    }

    /// Publishes a non-modal failure card for a cloud terminal request.
    @MainActor
    func presentTuiPaneCreationFailure(machine: SurfaceMachineID, error: Error, requestID: UUID, sourcePanelID: UUID? = nil) {
        #if DEBUG
        cmuxDebugLog("cloud.pane.createFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
        #endif
        tuiPaneCreationFailureStore.present(machine: machine, error: error, requestID: requestID, sourcePanelID: sourcePanelID ?? focusedPanelId)
    }
}
