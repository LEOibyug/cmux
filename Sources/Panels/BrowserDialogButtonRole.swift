/// The visual and semantic role of a native browser dialog button.
enum BrowserDialogButtonRole: String, Codable, Equatable, Sendable {
    /// The dialog's preferred affirmative action.
    case `default`
    /// An action that cancels or declines the request.
    case cancel
    /// An irreversible or security-sensitive action.
    case destructive
}
