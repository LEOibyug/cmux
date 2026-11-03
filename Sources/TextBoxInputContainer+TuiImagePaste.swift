import CmuxRemoteSession
import AppKit
import CmuxTui

extension TextBoxInputContainer {
    /// A composer must never submit a Mac path or send an attachment before Submit.
    func refuseTuiComposerImage(_ error: TuiImagePasteError = .useTerminal) {
        let alert = NSAlert()
        alert.messageText = String(localized: "tui.imagePaste.failed", defaultValue: "Image could not be pasted")
        alert.informativeText = error.localizedMessage
        if let window = surface.hostedView.window { alert.beginSheetModal(for: window) }
        else { NSSound.beep() }
    }

    /// Why the SSH session cannot send these image files from a composer, or `nil` when
    /// every one can be uploaded at submit. Checking type and size when an image
    /// is attached refuses it then, instead of failing the whole submit later.
    static func tuiComposerImageRefusal(for fileURLs: [URL]) -> TuiImagePasteError? {
        guard !fileURLs.isEmpty else { return .unsupportedType }
        for fileURL in fileURLs {
            do {
                try TuiClipboardImage.validateFile(at: fileURL)
            } catch let error as TuiImagePasteError {
                return error
            } catch {
                return .storage
            }
        }
        return nil
    }

    /// Inserts SSH image attachments into the composer without sending them
    /// to the terminal until the user submits the prompt.
    @discardableResult
    func insertTuiComposerImages(
        _ fileURLs: [URL],
        into textView: TextBoxInputTextView
    ) -> Bool {
        let attachments = fileURLs.map {
            TextBoxAttachment(
                localURL: $0.standardizedFileURL,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0),
                cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed($0)
            )
        }
        guard Self.tuiComposerImageRefusal(for: attachments.compactMap(\.localURL)) == nil,
              attachments.allSatisfy(\.isImage) else { return false }
        textView.insertAttachments(attachments)
        self.attachments = textView.inlineAttachments()
        text = textView.plainText()
        return true
    }

    /// Inserts prepared SSH image attachments without reopening their source
    /// files on the main actor.
    @discardableResult
    func insertPreparedTuiComposerImages(
        _ preparedAttachments: [TextBoxPreparedAttachment],
        into textView: TextBoxInputTextView,
        replacingPlaceholderID placeholderID: UUID
    ) -> Bool {
        let attachments = preparedAttachments.map {
            TextBoxAttachment(
                preparedAttachment: $0,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0.fileURL),
                cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed($0.fileURL)
            )
        }
        guard Self.tuiComposerImageRefusal(for: attachments.compactMap(\.localURL)) == nil,
              attachments.allSatisfy(\.isImage) else { return false }
        guard textView.replacePendingAttachmentUploadPlaceholder(
            id: placeholderID,
            with: attachments
        ) else { return false }
        self.attachments = textView.inlineAttachments()
        text = textView.plainText()
        return true
    }

    func attachFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        Task { @MainActor [self, weak textView] in
            guard let textView else { return }
            let runtimeGeneration = self.surface.runtimeSurfaceGeneration
            let target = await self.surface.resolvedImageTransferTargetAsync()
            guard self.surface.runtimeSurfaceGeneration == runtimeGeneration,
                  self.ownsTextView(textView) else { return }
            _ = self.attachFileURLs(
                standardizedURLs,
                into: textView,
                target: target
            )
        }
        return true
    }

    @MainActor
    private func attachFileURLs(
        _ fileURLs: [URL],
        into textView: TextBoxInputTextView,
        target: TerminalImageTransferTarget
    ) -> Bool {

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: fileURLs,
            target: target,
            mode: .paste
        )

        switch plan {
        case .insertText, .insertTextSegments:
            textView.insertAttachments(
                fileURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0),
                            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed($0)
                        )
                }
            )
            attachments = textView.inlineAttachments()
            text = textView.plainText()
            return true
        case .uploadFiles(let uploadURLs, let remoteTarget):
            uploadFileAttachments(uploadURLs, remoteTarget: remoteTarget, focusing: textView)
            return true
        case .pasteTuiImages:
            guard insertTuiComposerImages(fileURLs, into: textView) else {
                refuseTuiComposerImage(Self.tuiComposerImageRefusal(for: fileURLs) ?? .useTerminal)
                GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                return true
            }
            return true
        case .reject:
            return false
        }
    }

}
