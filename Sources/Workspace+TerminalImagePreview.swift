import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func openOrFocusTerminalImagePreview(from sourcePanelId: UUID, content: TerminalImagePreviewContent) -> Bool {
        guard !isRetiredFromOwningTabManager, panels[sourcePanelId] is TerminalPanel else { return false }
        if let preview = panels.values.lazy.compactMap({ $0 as? FilePreviewPanel }).first(where: { $0.terminalImage != nil }) {
            preview.updateTerminalImage(content, from: sourcePanelId)
            focusPanel(preview.id)
            return true
        }

        let preview: FilePreviewPanel?
        if let rightPane = preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            preview = newFilePreviewSurface(inPane: rightPane, source: .terminalImage(content), focus: true)
        } else if let sourcePane = paneId(forPanelId: sourcePanelId) {
            preview = splitPaneWithFilePreview(
                targetPane: sourcePane, orientation: .horizontal, insertFirst: false,
                source: .terminalImage(content)
            )
        } else {
            return false
        }
        guard let preview else { return false }
        preview.terminalImageSourcePanelId = sourcePanelId
        focusPanel(preview.id)
        return true
    }

    func restoreTerminalImageSourceAfterClose(_ sourcePanelId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRetiredFromOwningTabManager,
                  self.panels[sourcePanelId] is TerminalPanel,
                  self.owningTabManager.map({ $0.selectedTabId == self.id }) ?? true else { return }
            self.focusPanel(sourcePanelId)
        }
    }
}
