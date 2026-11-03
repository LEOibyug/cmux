/// A native Mac browser dialog tracked for native and automation answers.
struct BrowserDialogEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    let panelID: String
    /// Dialog UUID string used for exactly-once resolution.
    let dialogID: String
    /// Native browser interaction represented by this dialog.
    let kind: BrowserDialogKind
    /// Mac-provided title displayed verbatim, when present.
    let title: String?
    /// Mac-provided message displayed verbatim, when present.
    let message: String?
    /// Origin host associated with the request, when present.
    let host: String?
    /// Actions offered by the dialog.
    let buttons: [BrowserDialogButton]
    /// Text-entry metadata, when the dialog accepts text.
    let textField: BrowserDialogTextField?
    /// Whether the phone can only cancel while the interaction remains Mac-only.
    let informational: Bool

    /// Creates a native browser dialog event.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string.
    ///   - kind: Native browser interaction represented by the dialog.
    ///   - title: Mac-provided title displayed verbatim.
    ///   - message: Mac-provided message displayed verbatim.
    ///   - host: Origin host associated with the request.
    ///   - buttons: Actions offered by the dialog.
    ///   - textField: Text-entry metadata, when applicable.
    ///   - informational: Whether the interaction must be completed on the Mac.
    init(
        panelID: String,
        dialogID: String,
        kind: BrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [BrowserDialogButton],
        textField: BrowserDialogTextField?,
        informational: Bool
    ) {
        self.panelID = panelID
        self.dialogID = dialogID
        self.kind = kind
        self.title = title
        self.message = message
        self.host = host
        self.buttons = buttons
        self.textField = textField
        self.informational = informational
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case dialogID = "dialog_id"
        case kind
        case title
        case message
        case host
        case buttons
        case textField = "text_field"
        case informational
    }
}
