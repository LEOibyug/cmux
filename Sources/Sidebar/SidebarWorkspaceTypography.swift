import CoreGraphics

/// Shared semantic font hierarchy; callers supply their resolved sidebar scale.
struct SidebarWorkspaceTypography {
    let scale: CGFloat
    var settings = SidebarWorkspaceTextSettings()

    var title: CGFloat { settings.title * scale }
    var agentStatus: CGFloat { settings.agentStatus * scale }
    var description: CGFloat { settings.description * scale }
    var branch: CGFloat { settings.branch * scale }
    var directory: CGFloat { settings.directory * scale }
    var auxiliary: CGFloat { settings.auxiliary * scale }
}
