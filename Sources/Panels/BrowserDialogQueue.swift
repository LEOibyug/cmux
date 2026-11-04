/// Ordered pending-dialog state whose removal operation is the exactly-once claim.
struct BrowserDialogQueue: Equatable, Sendable {
    private var dialogs: [BrowserDialogEvent] = []

    /// Creates an empty pending-dialog queue.
    init() {}

    /// The oldest unresolved dialog for late-attaching subscribers.
    var current: BrowserDialogEvent? { dialogs.first }

    /// Every unresolved dialog in presentation order.
    var pending: [BrowserDialogEvent] { dialogs }

    /// Adds a dialog if its UUID is not already pending.
    /// - Parameter dialog: Dialog to add.
    /// - Returns: `true` when the dialog became pending.
    @discardableResult
    mutating func install(_ dialog: BrowserDialogEvent) -> Bool {
        guard !dialogs.contains(where: { $0.dialogID == dialog.dialogID }) else { return false }
        dialogs.append(dialog)
        return true
    }

    /// Atomically claims one dialog for resolution by removing it.
    /// - Parameter dialogID: UUID string of the dialog to claim.
    /// - Returns: The claimed dialog, or `nil` when another resolver already won.
    @discardableResult
    mutating func claim(dialogID: String) -> BrowserDialogEvent? {
        guard let index = dialogs.firstIndex(where: { $0.dialogID == dialogID }) else { return nil }
        return dialogs.remove(at: index)
    }

    /// Claims matching dialogs in one pass before any completion can run.
    /// - Parameter predicate: Selects dialogs to claim; defaults to all dialogs.
    /// - Returns: Dialogs claimed in presentation order.
    mutating func claimAll(
        where predicate: (BrowserDialogEvent) -> Bool = { _ in true }
    ) -> [BrowserDialogEvent] {
        var claimed: [BrowserDialogEvent] = []
        var remaining: [BrowserDialogEvent] = []
        for dialog in dialogs {
            if predicate(dialog) {
                claimed.append(dialog)
            } else {
                remaining.append(dialog)
            }
        }
        dialogs = remaining
        return claimed
    }
}
