/// Configurable workspace information groups shown below the title and agent status.
public enum SidebarWorkspaceDetail: String, CaseIterable, Sendable {
    /// The workspace's user-provided description.
    case description
    /// Notification messages and conversation previews.
    case notification
    /// Git branches and working directories.
    case branchDirectory
    /// Pull request summaries.
    case pullRequests
    /// Listening ports.
    case ports
    /// Custom workspace metadata.
    case metadata
    /// Workspace log messages.
    case log
    /// Workspace progress indicators.
    case progress

    /// Resolves a complete order, ignoring unknown values and repeated groups.
    ///
    /// Missing groups are appended in declaration order, preserving the default layout.
    ///
    /// - Parameter raw: Persisted raw values, which may omit groups or repeat them.
    /// - Returns: Every group exactly once, with recognized first occurrences first.
    ///
    /// ```swift
    /// let order = SidebarWorkspaceDetail.resolvedOrder(["ports", "ports", "unknown"])
    /// // [.ports, .description, .notification, .branchDirectory, .pullRequests,
    /// //  .metadata, .log, .progress]
    /// ```
    public static func resolvedOrder(_ raw: [String]) -> [Self] {
        var result: [Self] = []
        result.reserveCapacity(allCases.count)
        for value in raw {
            if let detail = Self(rawValue: value), !result.contains(detail) {
                result.append(detail)
            }
        }
        for detail in allCases where !result.contains(detail) {
            result.append(detail)
        }
        return result
    }
}
