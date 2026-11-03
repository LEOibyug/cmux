import CmuxRemoteSession
import AppKit

extension Workspace {
    /// Report a refused name without entering a process-modal loop or activating
    /// another window. Accepted graph names remain unchanged behind the sheet.
    func presentTuiRenameFailure(_ error: Error) {
        #if DEBUG
        cmuxDebugLog("cloud.rename.failed error=\(String(reflecting: error))")
        #endif
        presentTuiRenameFailure(message: String(
            localized: "socket.vm.renameFailed",
            defaultValue: "The remote name could not be changed. Refresh and try again."
        ))
    }

    /// Only localized product messages enter the sheet; backend details stay in diagnostics.
    func presentTuiRenameFailure(message: String) {
        guard let window = owningTabManager?.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "tuiPane.layoutSyncFailed.title", defaultValue: "Couldn’t update the machine workspace")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "tuiPane.newTerminalFailed.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window)
    }
}
