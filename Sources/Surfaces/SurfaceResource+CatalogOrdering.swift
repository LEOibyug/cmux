import CmuxSurfaceCatalogModel

extension SurfaceResource {
    /// Stable local/SSH ordering shared by catalog snapshots and command output.
    func catalogPrecedes(_ other: SurfaceResource) -> Bool {
        if machine != other.machine { return machine.rawValue < other.machine.rawValue }
        if kind != other.kind { return kind.rawValue < other.kind.rawValue }
        let lhs = remoteWorkspace?.index ?? -1
        let rhs = other.remoteWorkspace?.index ?? -1
        if lhs != rhs { return lhs < rhs }
        return id.key < other.id.key
    }
}
