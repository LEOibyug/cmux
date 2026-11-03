import AppKit
import CmuxSidebar
import QuartzCore

/// A fixed-height, compositor-animated lifecycle capsule shared by sidebar renderers.
@MainActor
final class AgentStatusBadgeView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let link = SidebarRowLinkButton()
    private let markdown = SidebarRowMarkdownTextView()
    private let arc = CAShapeLayer()
    private var presentation: AgentStatusPresentation?
    private var pointSize: CGFloat = 12
    private var content: NSView { !markdown.isHidden ? markdown : (link.isHidden ? label : link) }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(pointSize * 1.5 + 6))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for view in [iconView, label, link, markdown] { addSubview(view) }
        arc.fillColor = nil
        arc.lineCap = .round
        layer?.addSublayer(arc)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAnimation), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func configure(entry: SidebarStatusEntry, presentation: AgentStatusPresentation, fontScale: CGFloat, onOpenURL: @escaping (URL) -> Void) {
        self.presentation = presentation
        pointSize = 12 * fontScale
        let foreground = Self.color(presentation.foregroundHex)
        layer?.backgroundColor = Self.color(presentation.backgroundHex).cgColor
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(systemName: presentation.symbolName, pointSize: pointSize, weight: .semibold)
        iconView.contentTintColor = foreground
        iconView.imageScaling = .scaleProportionallyDown
        label.isHidden = true
        link.isHidden = true
        markdown.isHidden = true
        link.reset()
        markdown.reset()
        if entry.format == .markdown {
            markdown.isHidden = false
            markdown.configure(markdown: presentation.text, font: font, color: foreground, explicitURL: entry.url, onOpenURL: onOpenURL)
        } else if let url = entry.url {
            link.isHidden = false
            link.configure(title: presentation.text, font: font, color: foreground, underlined: true, toolTip: entry.sidebarToolTip(linkURL: url), onClick: { onOpenURL(url) })
        } else {
            label.isHidden = false
            label.stringValue = presentation.text
            label.font = font
            label.textColor = foreground
        }
        toolTip = entry.sidebarToolTip(linkURL: entry.url)
        arc.strokeColor = foreground.cgColor
        setAccessibilityLabel(presentation.text)
        invalidateIntrinsicContentSize()
        needsLayout = true
        refreshAnimation()
    }

    func reset() {
        presentation = nil
        arc.removeAnimation(forKey: "activity")
        arc.isHidden = true
        link.reset()
        markdown.reset()
    }

    override func layout() {
        super.layout()
        let height = intrinsicContentSize.height
        layer?.cornerRadius = height / 2
        let side = pointSize + 2
        let iconFrame = NSRect(x: 8, y: (height - side) / 2, width: side, height: side)
        iconView.frame = iconFrame
        let textX = iconFrame.maxX + 6
        let textHeight = ceil(pointSize * 1.5)
        content.frame = NSRect(x: textX, y: (height - textHeight) / 2, width: max(0, bounds.width - textX - 8), height: textHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = iconFrame
        arc.lineWidth = 1.8
        arc.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: side - 4, height: side - 4), transform: nil)
        arc.strokeStart = 0.05
        arc.strokeEnd = 0.78
        CATransaction.commit()
        refreshAnimation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let hit = super.hitTest(point)
        if hit === link || hit === markdown { return hit }
        return nil
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeVisibility(); refreshAnimation() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeVisibility(); refreshAnimation() }
    override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }

    private func observeVisibility() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(refreshAnimation), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(refreshAnimation), name: NSView.boundsDidChangeNotification, object: clip)
            }
            ancestor = view.superview
        }
    }

    @objc private func refreshAnimation() {
        let running = presentation?.isAnimating == true
        let animate = running && window != nil && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        arc.isHidden = !animate
        iconView.isHidden = animate
        if animate {
            if arc.animation(forKey: "activity") == nil {
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0
                rotation.toValue = Double.pi * 2
                rotation.duration = 1.2
                rotation.repeatCount = .infinity
                rotation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                arc.add(rotation, forKey: "activity")
            }
        } else {
            arc.removeAnimation(forKey: "activity")
        }
    }

    private static func color(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
