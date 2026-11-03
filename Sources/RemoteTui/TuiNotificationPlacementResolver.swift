import CmuxSurfaceCatalogModel
import Foundation

/// Where one of a machine's notifications lands on this Mac, resolved from the
/// catalog as it is right now, never from the placement at delivery time. The
/// same resolver answers both "where does this row go" at delivery and "which
/// rows does a read of this workspace or pane cover" at dismissal, so the two
/// can never disagree.
@MainActor
struct TuiNotificationPlacementResolver: Sendable {
    init(
        machine: SurfaceMachineID,
        projections: @escaping @MainActor (SurfaceResourceID) -> [SurfaceProjection],
        remoteWorkspaceIDs: @escaping @MainActor (_ terminalID: String) -> [String],
        boundWorkspaces: @escaping @MainActor () -> [TuiNotificationBoundWorkspace]
    ) {
        self.machine = machine
        self.projections = projections
        self.remoteWorkspaceIDs = remoteWorkspaceIDs
        self.boundWorkspaces = boundWorkspaces
    }

    /// A resolver for a graph that places each terminal in at most one remote
    /// workspace.
    init(
        machine: SurfaceMachineID,
        projections: @escaping @MainActor (SurfaceResourceID) -> [SurfaceProjection],
        remoteWorkspaceID: @escaping @MainActor (_ terminalID: String) -> String?,
        boundWorkspaces: @escaping @MainActor () -> [TuiNotificationBoundWorkspace]
    ) {
        self.init(
            machine: machine,
            projections: projections,
            remoteWorkspaceIDs: { remoteWorkspaceID($0).map { [$0] } ?? [] },
            boundWorkspaces: boundWorkspaces
        )
    }

    let machine: SurfaceMachineID
    /// Local panes showing a resource of this machine.
    var projections: @MainActor (SurfaceResourceID) -> [SurfaceProjection]
    /// The remote workspaces whose tabs show the terminal, from the accepted
    /// graph, in graph order.
    var remoteWorkspaceIDs: @MainActor (_ terminalID: String) -> [String]
    /// Local workspaces bound to the machine, in sidebar order.
    var boundWorkspaces: @MainActor () -> [TuiNotificationBoundWorkspace]

    /// The pane showing the terminal when one is open on this Mac, else the
    /// local workspace standing for the terminal's remote workspace. A
    /// terminal in a remote workspace the person has not opened here has no
    /// local home: the row stays undelivered until one exists and the SSH
    /// tree dot is its indicator, instead of stacking onto whichever local
    /// workspace happens to be bound to the machine (a workspace row then
    /// badges the whole machine's notifications, manaflow-ai/cmux#13000).
    /// Only a machine-level row (no terminal) lands on any local workspace
    /// bound to the machine. A terminal the accepted graph places in no
    /// workspace fails closed the same way: an unknown placement is not a
    /// machine-level one.
    func target(for row: TuiNotificationRow) -> TuiNotificationDeliveryTarget? {
        let bound = boundWorkspaces()
        guard let terminalID = row.terminalID else {
            return bound.first.map { TuiNotificationDeliveryTarget(workspaceID: $0.workspaceID, panelID: nil) }
        }
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        let resourceProjections = projections(resource)
        // A terminal can briefly have more than one local projection while a
        // SSH mirror is being moved between panes. Prefer the projection in
        // one of the daemon's remote workspaces for the terminal when that
        // identity is available. The catalog stores projections in a set and
        // hands them back sorted by `panelID.uuidString`, so without that
        // identity the ring lands on whichever duplicate happens to sort first.
        let terminalRemoteWorkspaceIDs = remoteWorkspaceIDs(terminalID)
        let preferredProjection = terminalRemoteWorkspaceIDs.lazy.compactMap { remoteWorkspaceID in
            resourceProjections.first { $0.remoteWorkspaceID == remoteWorkspaceID }
        }.first
        if let projection = preferredProjection ?? resourceProjections.first {
            return TuiNotificationDeliveryTarget(workspaceID: projection.workspaceID, panelID: projection.panelID)
        }
        for remoteWorkspaceID in terminalRemoteWorkspaceIDs {
            if let workspace = bound.first(where: { $0.remoteWorkspaceID == remoteWorkspaceID }) {
                return TuiNotificationDeliveryTarget(workspaceID: workspace.workspaceID, panelID: nil)
            }
        }
        return nil
    }
}
