import CmuxRemoteSession
import Bonsplit
import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation
import GhosttyKit

/// Optimistic Cloud terminal creation: the pane appears the moment the user asks
/// for it, the machine's terminal is created behind it, and the pane is adopted
/// when the attachment resolves.
///
/// One mutation path serves every entrypoint (⌘D/⌘⇧D/⌘T, the pane-divider split
/// button, the Cloud sidebar). The reservation records the pending state under a
/// request id; success reconciles from the authoritative projection, and failure
/// is shown inside the pane with Retry, never as a separate "starting" surface.
@MainActor
extension Workspace {
    /// Indexes the optimistic panes reserved for terminals in one remote
    /// workspace, by the exact terminal and tab each create receipt bound.
    /// Device layout reconciliation builds this once per pass and uses the same
    /// reservation for the pane it projects into and the pane it adopts, so the
    /// terminal lands in its final pane instead of the focused tab first.
    /// `tuiPendingCreations` is the only request-to-terminal record: an
    /// unbound or sibling reservation never lends its pane or queued input to
    /// another terminal.
    func pendingTuiTerminalReservations(
        remoteWorkspaceID: String
    ) -> [TuiTerminalReservationKey: TuiTerminalPaneReservation] {
        var index: [TuiTerminalReservationKey: TuiTerminalPaneReservation] = [:]
        for reservation in tuiPendingCreations.values where reservation.remoteWorkspaceID == remoteWorkspaceID {
            guard let resource = reservation.boundResourceID else { continue }
            let key = TuiTerminalReservationKey(resource: resource, remoteTabID: reservation.remoteTabID)
            if index[key] == nil { index[key] = reservation }
        }
        return index
    }



    /// A device may adopt this pane, and its router sends bytes only, so
    /// Ghostty must encode Enter, arrows and the other named keys itself.
    static func reservationKeyNameResolver(
        for machine: SurfaceMachineID
    ) -> (@MainActor @Sendable (ghostty_input_key_s) -> String?)? {
        return { event in RemoteTmuxKeyName(inputEvent: event)?.value }
    }

    func reserveRestoredTuiTerminalPane(
        snapshot: SessionPanelSnapshot,
        projection: SurfaceProjectionRecord,
        inPane pane: PaneID
    ) -> UUID? {
        guard projection.resource.kind == .terminal,
              !projection.resource.machine.isLocal else { return nil }
        let relay = TuiOptimisticInputRelay()
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: { input in relay.send(input) },
            keyNameResolver: Self.reservationKeyNameResolver(for: projection.resource.machine),
            allowsRemoteClipboardWrites: sshClipboardWriteTrustStore
                .allowsRemoteClipboardWrites(for: projection.resource.machine)
        ) else { return nil }
        panel.surface.setManualIONoReflow(false)
        do {
            let panelID = try insertTuiManualMirrorPanel(
                panel,
                at: .tab(workspaceID: id, paneID: pane.id.uuidString, index: nil),
                focus: false,
                isLoading: false
            )
            applySessionPanelMetadata(snapshot, toPanelId: panelID)
            tuiPendingCreations[panelID] = TuiTerminalPaneReservation(
                workspaceID: id,
                panelID: panelID,
                machine: projection.resource.machine,
                attachmentPlacement: SurfaceResourcePlacement(
                    resource: projection.resource,
                    remoteWorkspaceID: projection.remoteWorkspaceID,
                    remoteTabID: projection.remoteTabID
                ),
                inputRelay: relay
            )
            return panelID
        } catch {
            return nil
        }
    }

    /// Inserts the pane a Cloud terminal will occupy before the machine has created it.
    /// Returns nil when the destination no longer exists.
    func reserveTuiTerminalPane(
        machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        focus: Bool,
        sourcePlacement: TuiTerminalSourcePlacement? = nil,
        attachmentPlacement: SurfaceResourcePlacement? = nil,
        requestID: UUID? = nil
    ) -> TuiTerminalPaneReservation? {
        guard !isRetiredFromOwningTabManager,
              sourcePlacement.map({ $0.machine == machine }) ?? true,
              attachmentPlacement.map({ $0.resource.machine == machine }) ?? true,
              surfaceOwnershipPolicy.rejection(for: machine) == nil else { return nil }
        let relay = TuiOptimisticInputRelay()
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: { input in relay.send(input) },
            keyNameResolver: Self.reservationKeyNameResolver(for: machine),
            allowsRemoteClipboardWrites: sshClipboardWriteTrustStore
                .allowsRemoteClipboardWrites(for: machine)
        ) else { return nil }
        panel.surface.setManualIONoReflow(false)
        let reservation = TuiTerminalPaneReservation(
            workspaceID: id, panelID: panel.id, machine: machine,
            sourcePlacement: sourcePlacement, attachmentPlacement: attachmentPlacement,
            inputRelay: relay, requestID: requestID
        )
        // Insertion can synchronously publish focus/selection. Establish Cloud
        // identity first so a reentrant action cannot observe a local surface.
        tuiPendingCreations[panel.id] = reservation
        do {
            _ = try insertTuiManualMirrorPanel(panel, at: destination, focus: focus, isLoading: false)
        } catch {
            tuiPendingCreations.removeValue(forKey: panel.id)
            relay.discard()
            panel.close()
            return nil
        }
        guard tuiPendingCreations[panel.id] === reservation else { return nil }
        if focus { panel.surface.requestInputDemandSurfaceStartIfNeeded() }
        return reservation
    }

    /// Binds a resolved attachment to the reserved pane. Returns nil when the
    /// user already closed the pane, in which case the caller cancels.
    func adoptReservedTuiTerminalPane(
        _ reservation: TuiTerminalPaneReservation,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void,
        attachment: RemoteTerminalAttachmentStatus
    ) -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)? {
        guard !isRetiredFromOwningTabManager,
              tuiPendingCreations[reservation.panelID] === reservation,
              attachment.machineID == reservation.machine.tuiMachineID,
              let panel = panels[reservation.panelID] as? TerminalPanel,
              panel.surface.ioMode == .manualMirror else { return nil }
        Self.bindTuiManualMirrorCallbacks(
            panel: panel,
            onResize: onResize,
            onRuntimeReady: onRuntimeReady,
            onFocus: onFocus,
            attachment: attachment
        )
        clearTuiMaterializationFailure(surfaceID: reservation.panelID)
        panel.surface.flushPendingManualSizeReportIfAttached()
        return (id, panel.id, panel.surface)
    }

    /// The request completed: the projection either adopted the reserved pane or
    /// reused another one, in which case the now-redundant reservation closes.
    func completeReservedTuiTerminalPane(_ reservation: TuiTerminalPaneReservation, adoptedPanelID: UUID) {
        guard tuiPendingCreations[reservation.panelID] === reservation else { return }
        tuiPendingCreations.removeValue(forKey: reservation.panelID)
        reservation.closeAttachHandshake()
        if let resource = SurfaceCatalog.shared.resource(forPanel: adoptedPanelID) {
            reservation.creationReceipt.finish(.success(resource))
        }
        reservation.retry = nil
        reservation.cancel = nil
        if adoptedPanelID != reservation.panelID {
            // The user was in the reserved pane, so they follow the terminal it
            // was waiting for rather than landing on a neighbor.
            let handsOffFocus = focusedPanelId == reservation.panelID
            reservation.inputRelay.discard()
            SurfaceCatalog.shared.withProjectionEndReason(for: [reservation.panelID], reason: .replaced) {
                _ = closePanel(reservation.panelID, force: true)
            }
            if handsOffFocus, panels[adoptedPanelID] != nil {
                focusPanel(adoptedPanelID)
            }
        }
    }

    /// Creation or projection failed: keep the pane where the user put it and
    /// explain inside it, with Reconnect wired to the same request's retry.
    func failReservedTuiTerminalPane(_ reservation: TuiTerminalPaneReservation, error: Error) {
        guard tuiPendingCreations[reservation.panelID] === reservation else { return }
        reservation.creationReceipt.finish(.failure(error))
        reservation.closeAttachHandshake()
        let failure = TuiPaneCreationFailure(machine: reservation.machine, error: error)
        setTuiMaterializationFailure(
            surfaceID: reservation.panelID,
            detail: failure.errorText,
            reference: failure.copyableText
        )
    }

    /// A retry started: the pane is pending again.
    func restartReservedTuiTerminalPane(_ reservation: TuiTerminalPaneReservation) {
        guard tuiPendingCreations[reservation.panelID] === reservation else { return }
        clearTuiMaterializationFailure(surfaceID: reservation.panelID)
        // Keep the reserved tab visually stable while retrying. The pane itself
        // reports any failure through its reconnect affordance.
    }

    /// Reconnect pressed on a reserved pane's failure card replays the request.
    func retryReservedTuiTerminalPane(surfaceId: UUID) -> Bool {
        guard let reservation = tuiPendingCreations[surfaceId], let retry = reservation.retry else { return false }
        retry()
        return true
    }

    /// The pane left the workspace: end the local request. A remote terminal
    /// the machine already created stays alive, like closing any other pane.
    func cancelReservedTuiTerminalPane(panelID: UUID) {
        guard let reservation = tuiPendingCreations.removeValue(forKey: panelID) else { return }
        reservation.closeAttachHandshake()
        reservation.inputRelay.discard()
        reservation.creationReceipt.finish(.failure(TuiTransportError.placementMismatch))
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.retry = nil
        cancel?()
    }

    /// Drops a reservation when its remote workspace is invalidated before the
    /// provider create can begin. The pane is owned by this request, so leaving
    /// it visible would strand a loading surface after cancellation.
    func discardReservedTuiTerminalPane(_ reservation: TuiTerminalPaneReservation) {
        guard tuiPendingCreations[reservation.panelID] === reservation else { return }
        tuiPendingCreations.removeValue(forKey: reservation.panelID)
        reservation.closeAttachHandshake()
        reservation.inputRelay.discard()
        reservation.creationReceipt.finish(.failure(TuiTransportError.placementMismatch))
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.retry = nil
        cancel?()
        _ = closePanel(reservation.panelID, force: true)
    }

    /// Workspace teardown: every pending request ends without touching remote terminals.
    func cancelAllReservedTuiTerminalPanes() {
        for panelID in Array(tuiPendingCreations.keys) {
            cancelReservedTuiTerminalPane(panelID: panelID)
        }
    }
}
