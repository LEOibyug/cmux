/// One action offered by a native browser dialog.
struct BrowserDialogButton: Codable, Equatable, Sendable {
    /// Stable identifier returned in a dialog response.
    let id: String
    /// Mac-provided button label displayed verbatim in the dialog.
    let label: String
    /// Visual and semantic role of the action.
    let role: BrowserDialogButtonRole

    /// Creates a native browser dialog action.
    /// - Parameters:
    ///   - id: Stable identifier returned when the action is selected.
    ///   - label: Mac-provided label displayed verbatim.
    ///   - role: Visual and semantic role of the action.
    init(id: String, label: String, role: BrowserDialogButtonRole) {
        self.id = id
        self.label = label
        self.role = role
    }
}
