import SwiftUI

/// Covers Bonsplit's SwiftUI/tab-strip destinations; portal panes use the same policy.
struct TuiSurfaceDropGate: NSViewRepresentable {
    let workspaceID: UUID
    let isActive: Bool

    func makeNSView(context: Context) -> TuiSurfaceDropGateView {
        TuiSurfaceDropGateView(frame: .zero)
    }

    func updateNSView(_ view: TuiSurfaceDropGateView, context: Context) {
        view.workspace = Workspace.liveWorkspace(id: workspaceID)
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: TuiSurfaceDropGateView, coordinator: ()) {
        view.feedback.clear()
    }
}
