import CmuxRemoteSession
import AppKit
import SwiftUI

/// A native, pane-owned host. Connection state and creation failures share the
/// same responsive card, so a narrow terminal never gets a 260pt minimum dialog.
@MainActor
final class RemoteTerminalReconnectOverlayView: NSView {
    /// Identifies the card host inside the overlay. The card itself is SwiftUI,
    /// so its AppKit class is an implementation detail; this identifier is the
    /// stable handle for locating the laid-out card.
    static let cardAccessibilityIdentifier = "RemoteTerminalReconnectCard"

    var onReconnect: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var currentPresentation: RemoteTerminalReconnectOverlayPolicy.Presentation?
    /// The action wired to the card's Retry control, or nil when the current
    /// presentation offers no retry. This is the value handed to the card, so
    /// it is the same path the control invokes.
    private(set) var reconnectAction: (() -> Void)?
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var renderedWidth: CGFloat = 0
    private var needsContentUpdate = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.setAccessibilityIdentifier(Self.cardAccessibilityIdentifier)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        guard let presentation = currentPresentation else { return }
        let width = max(1, min(360, bounds.width - 24))
        if needsContentUpdate || renderedWidth != width {
            renderedWidth = width
            needsContentUpdate = false
            hostingView.rootView = AnyView(
                Content(
                    presentation: presentation,
                    onReconnect: reconnectAction,
                    onDismiss: { [weak self] in self?.onDismiss?() },
                    onCopy: { [weak self] in self?.copyCurrentError(nil) }
                )
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
            )
        }
        let height = ceil(hostingView.fittingSize.height)
        let frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        if hostingView.frame != frame { hostingView.frame = frame }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let localPoint = convert(point, from: superview)
        guard hostingView.frame.contains(localPoint) else { return nil }
        return hostingView.hitTest(localPoint) ?? self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentPresentation != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(localized: "contextMenu.copyError", defaultValue: "Copy Error"),
            action: #selector(copyCurrentError(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyCurrentError(_ sender: Any?) {
        guard let presentation = currentPresentation else { return }
        _ = GhosttyApp.terminalPasteboard.writeString(presentation.copyableError, to: .general)
    }

    func apply(_ presentation: RemoteTerminalReconnectOverlayPolicy.Presentation) {
        guard currentPresentation != presentation else { return }
        currentPresentation = presentation
        reconnectAction = presentation.showsReconnectButton
            ? { [weak self] in self?.onReconnect?() }
            : nil
        needsContentUpdate = true
        needsLayout = true
    }

    private struct Content: View {
        let presentation: RemoteTerminalReconnectOverlayPolicy.Presentation
        let onReconnect: (() -> Void)?
        let onDismiss: () -> Void
        let onCopy: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    if presentation.showsProgress {
                        ProgressView().controlSize(.small)
                    }
                    Text(presentation.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "contextMenu.copyError", defaultValue: "Copy Error"), action: onCopy)
                    Spacer(minLength: 0)
                    Button(String(localized: "common.dismiss", defaultValue: "Dismiss"), action: onDismiss)
                    if let onReconnect {
                        Button(String(localized: "common.retry", defaultValue: "Retry"), action: onReconnect)
                    }
                }
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}
