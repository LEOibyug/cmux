/// Parameters used when automation answers a native browser dialog.
struct BrowserDialogRespondParameters: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    let panelID: String
    /// Dialog UUID string being answered.
    let dialogID: String
    /// Selected action identifier.
    let buttonID: String
    /// Optional entered text; this value can contain a password and must never be logged.
    let text: String?

    /// Creates a native browser dialog response.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string being answered.
    ///   - buttonID: Selected action identifier.
    ///   - text: Optional entered text, which can be sensitive.
    init(panelID: String, dialogID: String, buttonID: String, text: String?) {
        self.panelID = panelID
        self.dialogID = dialogID
        self.buttonID = buttonID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case dialogID = "dialog_id"
        case buttonID = "button_id"
        case text
    }
}
