import Foundation

/// Complete immutable state rendered by the computer-use status item.
struct ComputerUseMenuBarSnapshot: Equatable, Sendable {
    static let hidden = ComputerUseMenuBarSnapshot(
        rows: [],
        hasRecentStateFiles: false,
        showInMenuBar: true
    )

    let rows: [ComputerUseMenuBarRow]
    let hasRecentStateFiles: Bool
    let showInMenuBar: Bool

    var shouldShowStatusItem: Bool {
        showInMenuBar && !rows.isEmpty
    }
}
