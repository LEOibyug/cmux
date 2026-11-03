public import CmuxSurfaceCatalogModel
import Foundation

/// Immutable Cloud identity captured at a terminal-create boundary.
///
/// A pending pane is a real terminal surface before its catalog projection exists.
/// Keeping its machine and remote workspace here lets the next split/new-terminal
/// action inherit the same placement even when focus has moved to that pane.
public struct TuiTerminalSourcePlacement: Sendable {
    public let machine: SurfaceMachineID
    public let resource: SurfaceResource?
    public let remoteWorkspaceID: String?
    public let remoteTabID: String?
    public let pendingCreation: TuiTerminalCreationReceipt?

    public init(
        machine: SurfaceMachineID,
        resource: SurfaceResource? = nil,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil,
        pendingCreation: TuiTerminalCreationReceipt? = nil
    ) {
        self.machine = machine
        self.resource = resource
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteTabID = remoteTabID
        self.pendingCreation = pendingCreation
    }

    /// Resolve the pending source's own tab, never its ancestor's layout anchor.
    @MainActor
    public func resolved() async throws -> TuiTerminalSourcePlacement {
        guard let pendingCreation else { return self }
        let created = try await pendingCreation.value()
        let view = try remoteView(of: created)
        guard view?.tabID.isEmpty == false else {
            // A dependent split must have an exact daemon tab anchor. The
            // workspace-only receipt is valid for its own pane but cannot safely
            // authorize a child layout mutation.
            throw TuiTransportError.placementMismatch
        }
        return TuiTerminalSourcePlacement(
            machine: machine, resource: created,
            remoteWorkspaceID: remoteWorkspaceID ?? view?.workspace.id ?? created.remoteWorkspace?.id,
            remoteTabID: view?.tabID
        )
    }

    /// A receipt is accepted only for this machine and captured remote workspace.
    public func validate(created: SurfaceResource) throws {
        guard created.machine == machine, created.kind == .terminal else {
            throw TuiTransportError.placementMismatch
        }
        if let remoteWorkspaceID {
            if let views = created.remoteViews, !views.isEmpty {
                guard views.contains(where: { $0.workspace.id == remoteWorkspaceID }) else {
                    throw TuiTransportError.placementMismatch
                }
            } else {
                guard created.remoteWorkspace?.id == remoteWorkspaceID else {
                    throw TuiTransportError.placementMismatch
                }
            }
        }
    }

    public func remoteView(of created: SurfaceResource) throws -> SurfaceRemoteView? {
        try validate(created: created)
        let views = (created.remoteViews ?? []).filter {
            remoteWorkspaceID == nil || $0.workspace.id == remoteWorkspaceID
        }
        guard views.count <= 1 else { throw TuiTransportError.placementMismatch }
        return views.first
    }

}
