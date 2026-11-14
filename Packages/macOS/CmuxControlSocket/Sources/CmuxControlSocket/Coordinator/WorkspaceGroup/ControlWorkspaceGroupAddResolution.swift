/// The outcome of adding one workspace to a group, including explicit
/// destination/reference validation failures.
public enum ControlWorkspaceGroupAddResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspace was added to the group.
    case added
    /// The group or workspace was not found, or the add no-op'd for an
    /// unspecified reason (legacy `not_found` / "Group or workspace not found").
    case notFound
    /// An explicit reference workspace was provided but is not a member of the
    /// target group.
    case invalidReferenceWorkspace
}
