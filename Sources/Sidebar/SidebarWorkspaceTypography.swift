import CoreGraphics

/// Shared semantic font hierarchy; callers supply their resolved sidebar scale.
struct SidebarWorkspaceTypography {
    let scale: CGFloat

    var title: CGFloat { 14 * scale }
    var agentStatus: CGFloat { 12 * scale }
    var description: CGFloat { 11 * scale }
    var branch: CGFloat { 10.5 * scale }
    var directory: CGFloat { 10 * scale }
    var auxiliary: CGFloat { 9.5 * scale }
}
