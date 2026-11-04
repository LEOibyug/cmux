import CmuxFoundation
import SwiftUI

// Keep the fullest existing display form (including home or alias shortening)
// and let the available width wrap it before tail truncation.
struct SidebarDirectoryText: View {
    let candidates: [String]
    let color: Color
    var fontScale: CGFloat = 1
    var textSettings = SidebarWorkspaceTextSettings()

    var body: some View {
        Text(candidates.first ?? "")
            .cmuxFont(size: SidebarWorkspaceTypography(scale: fontScale, settings: textSettings).directory, design: .monospaced)
            .foregroundColor(color)
            .lineLimit(textSettings.lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }
}
