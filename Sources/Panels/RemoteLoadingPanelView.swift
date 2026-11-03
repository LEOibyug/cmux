import SwiftUI
import CmuxAppKitSupportUI

struct RemoteLoadingPanelView: View {
    @ObservedObject var panel: RemoteLoadingPanel

    var body: some View {
        TimelineView(.periodic(from: panel.startedAt, by: 1)) { context in
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(panel.startedAt).rounded(.down)))
            let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
            VStack(spacing: 14) {
                switch panel.phase {
                case .loading(let headline):
                    ProgressView().controlSize(.small)
                    Text(headline ?? String(localized: "panel.remoteLoading.headline", defaultValue: "Opening SSH session"))
                        .cmuxFont(size: 14, weight: .semibold)
                    Text(String(format: String(localized: "panel.remoteLoading.elapsed", defaultValue: "%ds elapsed"), elapsedSeconds))
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                case .failed(let message, let elapsedSeconds):
                    CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18, tint: .orange)
                    Text(message)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Text(String(format: String(localized: "panel.remoteLoading.failed.elapsed", defaultValue: "Waited %ds before stopping."), elapsedSeconds))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: backgroundColor))
            .environment(\.colorScheme, WindowChromeColorResolver().readableColorScheme(for: backgroundColor))
        }
    }
}
