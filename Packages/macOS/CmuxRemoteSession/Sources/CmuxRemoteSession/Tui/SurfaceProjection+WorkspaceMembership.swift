public import CmuxSurfaceCatalogModel

extension SurfaceProjection {
    /// Local forwarded-port previews have no daemon tab.
    public var isLocalWorkspaceView: Bool {
        remoteTabID == nil && resource.isForwardedPort
    }

    /// Explicit previews have no daemon tab. Their live catalog projections name
    /// their bound workspace; availability in the machine resource pool never does.
    /// A daemon placement of the same resource already supplies that workspace row.
    public static func localWorkspaceMembers(resources: [SurfaceResource], projections: [SurfaceProjection]) -> [(resource: SurfaceResource, workspaceID: String)] {
        let previews = Dictionary(
            resources.filter { $0.id.isForwardedPort }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Daemon placements already supply their workspace membership.
        var seen: [SurfaceResourceID: Set<String>] = [:]
        for resource in resources {
            for workspace in resource.remoteWorkspaces {
                seen[resource.id, default: []].insert(workspace.id)
            }
        }
        return projections.compactMap { projection in
            guard projection.isLocalWorkspaceView,
                  let workspaceID = projection.remoteWorkspaceID,
                  let resource = previews[projection.resource],
                  seen[resource.id, default: []].insert(workspaceID).inserted else { return nil }
            return (resource, workspaceID)
        }
    }
}
