import AppKit
import SwiftUI

struct ControlCenterChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let focusRequest: Int
    let canSend: Bool
    let onSend: () -> Void

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
        editor.needsInitialFocus = true
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
        scrollView.editor.canSend = canSend
        scrollView.editor.onSend = { [weak coordinator, weak scrollView] in
            guard let coordinator, let scrollView else { return }
            coordinator.parent.text = scrollView.editor.string
            coordinator.parent.onSend()
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
    var onSend: (() -> Void)?
    var focusRequest = 0
    var needsInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if needsInitialFocus, window != nil {
            needsInitialFocus = false
            requestFocus()
        }
    }

    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(), isReturn(event) else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty && canSend {
            onSend?()
        } else if flags == .command {
            if canSend { onSend?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isReturn(event), flags == .command, !hasMarkedText() {
            if canSend { onSend?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }
}
