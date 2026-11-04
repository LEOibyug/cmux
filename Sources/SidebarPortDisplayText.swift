import Foundation

enum SidebarPortDisplayText {
    static func label(for port: Int) -> String {
        ":" + String(port)
    }

    static func openTooltip(for port: Int) -> String {
        String(
            format: String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost:%lld"),
            Int64(port)
        )
    }
}
