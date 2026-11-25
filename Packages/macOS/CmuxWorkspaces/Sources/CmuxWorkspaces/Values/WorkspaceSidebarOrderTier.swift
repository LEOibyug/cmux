/// The fixed top-level sidebar order; group members stay within their group.
public enum WorkspaceSidebarOrderTier: Int, CaseIterable, Sendable {
    case pinnedGroup
    case pinnedWorkspace
    case group
    case workspace

    public init(isGroup: Bool, isPinned: Bool) {
        self = isGroup
            ? (isPinned ? .pinnedGroup : .group)
            : (isPinned ? .pinnedWorkspace : .workspace)
    }
}
