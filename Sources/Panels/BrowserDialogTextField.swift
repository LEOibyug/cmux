/// Text-entry metadata for a native browser dialog.
struct BrowserDialogTextField: Codable, Equatable, Sendable {
    /// Mac-provided placeholder displayed verbatim, when present.
    let placeholder: String?
    /// Initial field value, when present.
    let initial: String?
    /// Whether entered text must be obscured and treated as sensitive.
    let secure: Bool

    /// Creates mirrored text-entry metadata.
    /// - Parameters:
    ///   - placeholder: Mac-provided placeholder displayed verbatim.
    ///   - initial: Initial field value.
    ///   - secure: Whether entered text must be obscured and treated as sensitive.
    init(placeholder: String?, initial: String?, secure: Bool) {
        self.placeholder = placeholder
        self.initial = initial
        self.secure = secure
    }
}
