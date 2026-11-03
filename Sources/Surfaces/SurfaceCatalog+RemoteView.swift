import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {

    /// Resolves an exact daemon placement or a local forwarded-port preview.
    func remoteView(
        for placement: SurfaceResourcePlacement,
        fallbackWorkspaceID: String? = nil
    ) throws -> SurfaceRemoteView? {
        let workspaceID = placement.remoteWorkspaceID ?? fallbackWorkspaceID
        if let resource = resources[placement.resource],
           placement.remoteTabID == nil,
           resource.remoteViews == nil,
           resource.id.isForwardedPort {
            return nil
        }
        return try remoteView(
            for: placement.resource,
            tabID: placement.remoteTabID,
            workspaceID: workspaceID
        )
    }

    /// Resolves a group placement without falling back to an unrelated resource view.
    func resolveRemoteView(
        for member: SurfaceResourcePlacement,
        fallbackWorkspaceID: String?
    ) throws -> SurfaceRemoteView? {
        guard resources[member.resource] != nil else { return nil }
        if member.remoteTabID == nil,
           let workspaceID = member.remoteWorkspaceID ?? fallbackWorkspaceID,
           projections.contains(where: {
               $0.resource == member.resource && $0.isLocalWorkspaceView && $0.remoteWorkspaceID == workspaceID
           }) {
            return nil
        }
        return try remoteView(for: member, fallbackWorkspaceID: fallbackWorkspaceID)
    }

    /// Resolves an agent-provided remote placement against the latest accepted
    /// graph. A workspace id alone is valid only when it identifies one view;
    /// callers that need a particular tab must provide `tabID`.
    func remoteView(
        for id: SurfaceResourceID,
        tabID: String? = nil,
        workspaceID: String? = nil
    ) throws -> SurfaceRemoteView? {
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        guard let views = resource.remoteViews else {
            if tabID != nil || workspaceID != nil {
                throw SurfaceCatalogError.unavailable(id, reason: "remote placement data is unavailable")
            }
            return nil
        }
        if let tabID {
            let matches = views.filter { $0.tabID == tabID }
            guard matches.count == 1, let view = matches.first else {
                if matches.count > 1 {
                    throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) has ambiguous placement")
                }
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is no longer present")
            }
            if let workspaceID, view.workspace.id != workspaceID {
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is not in workspace \(workspaceID)")
            }
            return view
        }
        guard let workspaceID else { return nil }
        let matches = views.filter { $0.workspace.id == workspaceID }
        guard matches.count <= 1 else {
            throw SurfaceCatalogError.ambiguousRemotePlacement(id, workspaceID: workspaceID)
        }
        guard let view = matches.first else {
            throw SurfaceCatalogError.unavailable(id, reason: "remote workspace \(workspaceID) has no view of this resource")
        }
        return view
    }

}
