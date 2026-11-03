import Foundation

/// Owns native browser completions, including deferred automation dialogs.
@MainActor
final class BrowserDialogBroker {
    typealias Resolver = @MainActor (_ buttonID: String, _ text: String?) -> Void
    typealias Dismissal = @MainActor () -> Void

    private struct PendingResolution {
        let resolve: Resolver
        var dismiss: Dismissal?
    }

    let panelID: String
    private var queue = BrowserDialogQueue()
    private var resolutions: [String: PendingResolution] = [:]

    init(panelID: String) {
        self.panelID = panelID
    }

    var currentDialog: BrowserDialogEvent? { queue.current }
    var pendingDialogs: [BrowserDialogEvent] { queue.pending }

    @discardableResult
    func begin(
        kind: BrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [BrowserDialogButton],
        textField: BrowserDialogTextField?,
        informational: Bool,
        resolve: @escaping Resolver
    ) -> BrowserDialogEvent {
        let dialog = BrowserDialogEvent(
            panelID: panelID,
            dialogID: UUID().uuidString,
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: buttons,
            textField: textField,
            informational: informational
        )
        _ = queue.install(dialog)
        resolutions[dialog.dialogID] = PendingResolution(resolve: resolve, dismiss: nil)
        return dialog
    }

    func attachDismissal(dialogID: String, dismissal: @escaping Dismissal) {
        guard var pending = resolutions[dialogID] else {
            dismissal()
            return
        }
        pending.dismiss = dismissal
        resolutions[dialogID] = pending
    }

    @discardableResult
    func respond(_ response: BrowserDialogRespondParameters) -> Bool {
        guard response.panelID == panelID,
              let dialog = queue.pending.first(where: { $0.dialogID == response.dialogID }),
              dialog.buttons.contains(where: { $0.id == response.buttonID }),
              queue.claim(dialogID: response.dialogID) != nil,
              let pending = resolutions.removeValue(forKey: response.dialogID) else {
            return false
        }
        pending.resolve(response.buttonID, response.text)
        pending.dismiss?()
        return true
    }

    @discardableResult
    func resolveFromMac(dialogID: String, action: @escaping @MainActor () -> Void) -> Bool {
        guard queue.claim(dialogID: dialogID) != nil,
              resolutions.removeValue(forKey: dialogID) != nil else {
            return false
        }
        action()
        return true
    }

    /// Claims the batch before callbacks so teardown cannot resolve a dialog twice.
    func resolveAll(where predicate: (BrowserDialogEvent) -> Bool = { _ in true }) {
        let claimed = queue.claimAll(where: predicate).compactMap { dialog -> (BrowserDialogEvent, PendingResolution)? in
            guard let pending = resolutions.removeValue(forKey: dialog.dialogID) else { return nil }
            return (dialog, pending)
        }
        for (dialog, pending) in claimed {
            let cancelButton = dialog.buttons.first(where: { $0.role == .cancel }) ?? dialog.buttons.first
            pending.resolve(cancelButton?.id ?? "cancel", nil)
            pending.dismiss?()
        }
    }
}
