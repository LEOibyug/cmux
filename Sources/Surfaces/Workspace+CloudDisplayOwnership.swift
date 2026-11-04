import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    /// A saved browser URL never establishes remote ownership by itself.
    func acceptsRestoredPanel(_ snapshot: SessionPanelSnapshot, projection: SurfaceProjectionRecord?, policy: SurfaceOwnershipPolicy? = nil) -> Bool {
        let policy = policy ?? surfaceOwnershipPolicy
        if let resource = snapshot.browser?.remoteResource {
            if let projection, projection.resource != resource { return false }
            return policy.rejection(for: resource.machine, kind: resource.kind) == nil
        }
        if let projection { return policy.rejection(for: projection.resource.machine, kind: projection.resource.kind) == nil }
        return true
    }

    /// Validate the complete saved layout before clearing panels or adopting a
    /// binding. Startup may adopt a saved owner; an already bound workspace may
    /// never be rebound as a side effect of restoring foreign display views.
    func acceptsRestoredSession(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        let savedOwner = Self.restoredRemoteWorkspaceBinding(from: snapshot.remoteWorkspace).flatMap { SurfaceMachineID(rawValue: $0.machineID) }
        if let owner = surfaceOwnershipPolicy.remoteMachine, savedOwner != owner { return false }
        let policy = SurfaceOwnershipPolicy(remoteMachine: savedOwner ?? surfaceOwnershipPolicy.remoteMachine)
        let records = snapshot.surfaceProjections ?? []
        if !records.isEmpty, policy.rejection(for: records.map(\.resource)) != nil { return false }
        let byPanel = Dictionary(records.map { ($0.panelID, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.panels.allSatisfy { acceptsRestoredPanel($0, projection: byPanel[$0.id], policy: policy) }
    }
}
