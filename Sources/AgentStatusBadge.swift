import CmuxSidebar
import SwiftUI

@MainActor
struct AgentStatusBadge: NSViewRepresentable {
    let entry: SidebarStatusEntry
    let presentation: AgentStatusPresentation
    let pointSize: CGFloat
    let displaySettings: AgentStatusDisplaySettings
    var lineLimit: Int = 2
    let onOpenURL: (URL) -> Void

    func makeNSView(context: Context) -> AgentStatusBadgeView {
        AgentStatusBadgeView()
    }

    func updateNSView(_ view: AgentStatusBadgeView, context: Context) {
        view.configure(entry: entry, presentation: presentation, pointSize: pointSize, displaySettings: displaySettings, lineLimit: lineLimit, onOpenURL: onOpenURL)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentStatusBadgeView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.measuredHeight(width: width))
    }

    static func dismantleNSView(_ view: AgentStatusBadgeView, coordinator: ()) {
        view.reset()
    }
}
