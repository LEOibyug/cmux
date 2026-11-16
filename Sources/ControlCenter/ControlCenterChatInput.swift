import AppKit
import CmuxAppKitSupportUI
import SwiftUI
import UniformTypeIdentifiers

struct ControlCenterChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let focusRequest: Int
    let isVisible: Bool
    let canSend: Bool
    let historyActive: Bool
    let colorScheme: ColorScheme
    let textColor: NSColor
    let insertionPointColor: NSColor
    let onSend: () -> Void
    let onRecall: (Int) -> Void
    let onImageURLs: ([URL]) -> Void
    let onImageData: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ChatInputScrollView {
        let scrollView = ChatInputScrollView()
        let editor = scrollView.editor
        editor.delegate = context.coordinator
        editor.string = text
        editor.setAccessibilityLabel(ControlCenterStrings.text("chatInputLabel"))
        editor.setAccessibilityIdentifier("controlCenter.chatInput")
        configure(scrollView, coordinator: context.coordinator)
        editor.focusRequest = focusRequest
        editor.needsInitialFocus = isVisible
        return scrollView
    }

    func updateNSView(_ scrollView: ChatInputScrollView, context: Context) {
        context.coordinator.parent = self
        configure(scrollView, coordinator: context.coordinator)
        let editor = scrollView.editor
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            let count = text.utf16.count
            editor.setSelectedRange(NSRange(location: count, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        if editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            editor.requestFocus()
        }
        scrollView.needsLayout = true
    }

    private func configure(_ scrollView: ChatInputScrollView, coordinator: Coordinator) {
        let appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        if scrollView.appearance?.name != appearance.name {
            scrollView.appearance = appearance
        }
        if scrollView.editor.appearance?.name != appearance.name {
            scrollView.editor.appearance = appearance
        }
        if scrollView.editor.textColor != textColor {
            scrollView.editor.textColor = textColor
        }
        if scrollView.editor.insertionPointColor != insertionPointColor {
            scrollView.editor.insertionPointColor = insertionPointColor
        }
        scrollView.editor.typingAttributes[.foregroundColor] = textColor
        scrollView.isHidden = !isVisible
        scrollView.editor.isInputActive = isVisible
        scrollView.editor.isEditable = isVisible
        scrollView.editor.isSelectable = isVisible
        if !isVisible, let window = scrollView.window, window.firstResponder === scrollView.editor {
            window.makeFirstResponder(nil)
        }
        scrollView.editor.canSend = canSend
        scrollView.editor.historyActive = historyActive
        scrollView.editor.onSend = { [weak coordinator, weak scrollView] in
            guard let coordinator, let scrollView else { return }
            coordinator.parent.text = scrollView.editor.string
            coordinator.parent.onSend()
        }
        scrollView.editor.onRecall = { [weak coordinator] direction in coordinator?.parent.onRecall(direction) }
        scrollView.editor.onImageURLs = { [weak coordinator] urls in coordinator?.parent.onImageURLs(urls) }
        scrollView.editor.onImageData = { [weak coordinator] data, name in coordinator?.parent.onImageData(data, name) }
        scrollView.editor.onFocusChange = { [weak coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            DispatchQueue.main.async {
                coordinator.parent.isFocused = focused
            }
        }
        scrollView.onHeightChange = { [weak coordinator] height in
            guard let coordinator, abs(coordinator.parent.measuredHeight - height) > 0.5 else { return }
            coordinator.parent.measuredHeight = height
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ControlCenterChatInput

        init(parent: ControlCenterChatInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.enclosingScrollView?.needsLayout = true
        }
    }
}

final class ChatInputScrollView: NSScrollView {
    let editor = ChatInputTextView(frame: .zero)
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 48)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        documentView = editor
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
        let width = contentSize.width
        if abs(editor.frame.width - width) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        }
        layoutManager.ensureLayout(for: container)
        let textHeight = max(layoutManager.usedRect(for: container).maxY, layoutManager.extraLineFragmentRect.maxY)
        let contentHeight = ceil(textHeight + editor.textContainerInset.height * 2)
        let height = min(164, max(48, contentHeight))
        let documentHeight = max(contentSize.height, contentHeight)
        if abs(editor.frame.height - documentHeight) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: documentHeight))
        }
        guard height != lastHeight else { return }
        lastHeight = height
        DispatchQueue.main.async { [weak self] in self?.onHeightChange?(height) }
    }
}

final class ChatInputTextView: NSTextView {
    var canSend = false
    var historyActive = false
    var onSend: (() -> Void)?
    var onRecall: ((Int) -> Void)?
    var onImageURLs: (([URL]) -> Void)?
    var onImageData: ((Data, String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var focusRequest = 0
    var needsInitialFocus = false
    var isInputActive = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onFocusChange?(false) }
        if needsInitialFocus, window != nil {
            needsInitialFocus = false
            requestFocus()
        }
    }

    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInputActive, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isInputActive, flags.isEmpty, selectedRange().length == 0 {
            let position = selectedRange().location
            if event.keyCode == 126, position == 0 || historyActive {
                onRecall?(-1)
                return
            }
            if event.keyCode == 125, position == string.utf16.count {
                onRecall?(1)
                return
            }
        }
        guard isReturn(event) else {
            super.keyDown(with: event)
            return
        }
        if flags.isEmpty && canSend {
            onSend?()
        } else if flags == .command {
            if canSend { onSend?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isInputActive else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isReturn(event), flags == .command, !hasMarkedText() {
            if canSend { onSend?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if !receiveImages(from: .general) { super.paste(sender) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isInputActive, hasImages(in: sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if receiveImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func imageURLs(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    private func hasImages(in pasteboard: NSPasteboard) -> Bool {
        !imageURLs(in: pasteboard).isEmpty || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func receiveImages(from pasteboard: NSPasteboard) -> Bool {
        guard isInputActive else { return false }
        let urls = imageURLs(in: pasteboard)
        if !urls.isEmpty {
            onImageURLs?(urls)
            return true
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            onImageData?(data, type == .png ? "pasted-image.png" : "pasted-image.tiff")
            return true
        }
        return false
    }

    private func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }
}
