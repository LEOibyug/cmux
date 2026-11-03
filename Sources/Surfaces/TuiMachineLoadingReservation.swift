import CmuxRemoteSession
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

/// An immutable claim on one creating pane, retained only by its attachment task.
/// The factory checks the claim before any native pane mutation, so cancellation
/// cannot turn a delayed adoption into an ordinary new-terminal insertion.
struct TuiMachineLoadingReservation: Sendable {
    /// The claim bound by the enclosing ``withCurrent(_:isolation:operation:)``.
    static var current: Self? { boundReservation?.value }

    // UUID fields give this value a run-time size; bind it by reference so
    // macOS 14's back-deployed TaskLocal fallback cannot abort.
    @TaskLocal private static var boundReservation: TaskLocalReference<TuiMachineLoadingReservation>?

    /// Runs `operation` with `reservation` as ``current``; `nil` clears an
    /// enclosing claim.
    static func withCurrent<T>(
        _ reservation: Self?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $boundReservation.withReferencedValue(reservation, isolation: isolation, operation: operation)
    }

    let workspaceID: UUID
    let panelID: UUID
    let machineID: String
    let expectedRemoteWorkspaceID: String?
    let expectedRemoteTabID: String?

    @MainActor
    init?(_ resource: SurfaceResourceID, at destination: SurfaceDestination, remoteView: SurfaceRemoteView? = nil) {
        guard resource.kind == .terminal, let machineID = resource.machine.tuiMachineID,
              let workspace = Workspace.liveWorkspace(id: destination.workspaceID),
              let loading = workspace.tuiMachineLoadingPanel(at: destination, machineID: machineID) else { return nil }
        workspaceID = workspace.id
        panelID = loading.id
        self.machineID = machineID
        expectedRemoteWorkspaceID = remoteView?.workspace.id
        expectedRemoteTabID = remoteView?.tabID
    }

    @MainActor
    func loadingPanel(at destination: SurfaceDestination, machineID: String?) throws -> RemoteLoadingPanel {
        guard destination.workspaceID == workspaceID, machineID == self.machineID,
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              !workspace.isRetiredFromOwningTabManager,
              workspace.remoteWorkspaceBinding?.machineID == self.machineID,
              let loading = workspace.panels[panelID] as? RemoteLoadingPanel else { throw CancellationError() }
        return loading
    }

    @MainActor
    func validate(materializedPlacement: SurfaceRemotePlacement?) throws {
        guard let expectedRemoteTabID else { return }
        guard let materializedPlacement,
              materializedPlacement.workspaceID == expectedRemoteWorkspaceID,
              materializedPlacement.tabID == expectedRemoteTabID else { throw TuiTransportError.placementMismatch }
    }
}


