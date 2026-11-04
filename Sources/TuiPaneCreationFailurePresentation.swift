import AppKit
import CmuxRemoteSession
import SwiftUI

/// Presents the originating pane's SSH creation failure above native portals.
@MainActor
struct TuiPaneCreationFailurePresentation: ViewModifier {
    let failureStore: TuiPaneCreationFailureStore
    var isWorkspaceVisible = true
    var sourceView: NSView?

    func body(content: Content) -> some View {
        content.background {
            NativeOverlay(
                failure: isWorkspaceVisible ? failureStore.failure : nil,
                sourceView: sourceView,
                onRetry: failureStore.canRetry ? { [weak failureStore] id in failureStore?.retry(id: id) } : nil,
                onDismiss: { [weak failureStore] id in failureStore?.dismiss(id: id) }
            )
        }
    }

    private struct NativeOverlay: NSViewRepresentable {
        let failure: TuiPaneCreationFailure?
        let sourceView: NSView?
        let onRetry: ((UUID) -> Void)?
        let onDismiss: (UUID) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> AnchorView {
            let view = AnchorView()
            view.coordinator = context.coordinator
            context.coordinator.anchor = view
            return view
        }

        func updateNSView(_ view: AnchorView, context: Context) {
            context.coordinator.update(
                failure: failure,
                layoutDirection: context.environment.layoutDirection,
                colorScheme: context.environment.colorScheme,
                sourceView: sourceView,
                onRetry: onRetry,
                onDismiss: onDismiss
            )
        }

        static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
            view.coordinator = nil
            coordinator.removeCard()
        }

        @MainActor
        final class AnchorView: NSView {
            weak var coordinator: Coordinator?
            override var isHidden: Bool {
                didSet { coordinator?.synchronize() }
            }
            override func viewWillMove(toWindow newWindow: NSWindow?) {
                if newWindow !== window { coordinator?.removeCard() }
                super.viewWillMove(toWindow: newWindow)
            }
            override func viewWillMove(toSuperview newSuperview: NSView?) {
                if newSuperview == nil { coordinator?.removeCard() }
                super.viewWillMove(toSuperview: newSuperview)
            }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                coordinator?.synchronize()
            }
            override func layout() {
                super.layout()
                coordinator?.synchronize()
            }
            override func setFrameOrigin(_ newOrigin: NSPoint) {
                super.setFrameOrigin(newOrigin)
                coordinator?.synchronize()
            }
            override func setFrameSize(_ newSize: NSSize) {
                super.setFrameSize(newSize)
                coordinator?.synchronize()
            }
        }

        @MainActor
        final class Coordinator {
            private struct RenderState: Equatable {
                let failure: TuiPaneCreationFailure
                let width: CGFloat
                let layoutDirection: LayoutDirection
                let colorScheme: ColorScheme
                let canRetry: Bool
            }

            weak var anchor: AnchorView?
            private var failure: TuiPaneCreationFailure?
            private var onDismiss: ((UUID) -> Void)?
            private var onRetry: ((UUID) -> Void)?
            private var layoutDirection: LayoutDirection = .leftToRight
            private var colorScheme: ColorScheme = .light
            private var card: NSHostingView<AnyView>?
            private var rendered: RenderState?
            private weak var sourceView: NSView?
            private var geometryObservers: [NSObjectProtocol] = []
            private var observedViews: [ObjectIdentifier] = []
            private var isSynchronizing = false
            private let chromeComposition = AppWindowChromeComposition()

            func update(
                failure: TuiPaneCreationFailure?,
                layoutDirection: LayoutDirection,
                colorScheme: ColorScheme,
                sourceView: NSView?,
                onRetry: ((UUID) -> Void)?,
                onDismiss: @escaping (UUID) -> Void
            ) {
                self.failure = failure
                self.layoutDirection = layoutDirection
                self.colorScheme = colorScheme
                self.sourceView = sourceView
                self.onRetry = onRetry
                self.onDismiss = onDismiss
                synchronize()
            }

            func removeCard() {
                card?.removeFromSuperview()
                card = nil
                rendered = nil
                geometryObservers.forEach(NotificationCenter.default.removeObserver)
                geometryObservers.removeAll()
                observedViews.removeAll()
            }

            deinit { geometryObservers.forEach(NotificationCenter.default.removeObserver) }

            private func observeGeometry(from source: NSView, through container: NSView) {
                var views: [NSView] = []
                var current: NSView? = source
                while let view = current, view !== container {
                    views.append(view)
                    current = view.superview
                }
                let identities = views.map(ObjectIdentifier.init)
                guard observedViews != identities else { return }
                geometryObservers.forEach(NotificationCenter.default.removeObserver)
                geometryObservers.removeAll()
                observedViews = identities
                for view in views {
                    view.postsFrameChangedNotifications = true
                    view.postsBoundsChangedNotifications = true
                    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                        geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.synchronize() }
                        })
                    }
                }
            }

            func synchronize() {
                // Measuring SwiftUI can synchronously lay out the native anchor.
                guard !isSynchronizing else { return }
                isSynchronizing = true
                defer { isSynchronizing = false }
                guard let failure, let anchor, let window = anchor.window, let sourceView,
                      !anchor.isHiddenOrHasHiddenAncestor,
                      sourceView.window === window, !sourceView.isHiddenOrHasHiddenAncestor,
                      let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
                    removeCard()
                    return
                }
                observeGeometry(from: sourceView, through: target.container)
                let bounds = target.container.convert(sourceView.visibleRect, from: sourceView)
                    .intersection(target.container.convert(target.reference.bounds, from: target.reference))
                guard !bounds.isNull, bounds.width > 32, bounds.height > 24 else {
                    removeCard()
                    return
                }
                let width = min(360, bounds.width - 24)
                let nextRender = RenderState(failure: failure, width: width, layoutDirection: layoutDirection,
                                             colorScheme: colorScheme, canRetry: onRetry != nil)
                let needsMeasurement = card == nil || rendered != nextRender
                let host: NSHostingView<AnyView>
                if let card, rendered == nextRender {
                    host = card
                } else {
                    let root = AnyView(
                        FailureCard(
                            failure: failure,
                            onRetry: onRetry == nil ? nil : { [weak self] in self?.onRetry?(failure.id) },
                            onDismiss: { [weak self] in self?.onDismiss?(failure.id) }
                        )
                        .environment(\.layoutDirection, layoutDirection)
                        .environment(\.colorScheme, colorScheme)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    )
                    host = card ?? NSHostingView(rootView: root)
                    host.rootView = root
                    host.identifier = NSUserInterfaceItemIdentifier("cmux.tuiPaneCreationFailure.card")
                    host.sizingOptions = [.intrinsicContentSize]
                    host.wantsLayer = true
                    host.layer?.backgroundColor = NSColor.clear.cgColor
                    card = host
                    rendered = nextRender
                }
                if host.superview !== target.container {
                    host.removeFromSuperview()
                    // Stay above terminal/browser portals, below other foreground controls.
                    let foregroundSurface = target.container.subviews.last {
                        $0 is WindowTerminalHostView || $0 is WindowBrowserHostView
                    } ?? target.reference
                    target.container.addSubview(host, positioned: .above, relativeTo: foregroundSurface)
                }
                let height = needsMeasurement ? ceil(host.fittingSize.height) : host.frame.height
                let frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height)
                if host.frame != frame { host.frame = frame }
            }
        }
    }

    private struct FailureCard: View {
        let failure: TuiPaneCreationFailure
        let onRetry: (() -> Void)?
        let onDismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(failure.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help(String(localized: "common.dismiss", defaultValue: "Dismiss"))
                    .accessibilityLabel(String(localized: "common.dismiss", defaultValue: "Dismiss"))
                    .accessibilityIdentifier("TuiPaneCreationFailureDismiss")
                }
                Text(failure.errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.recoveryText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetry {
                    Button(String(localized: "common.retry", defaultValue: "Retry"), action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("TuiPaneCreationFailureRetry")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ghosttyDialogSurface(cornerRadius: 0)
            .accessibilityIdentifier("TuiPaneCreationFailure")
            .contextMenu {
                Button(String(localized: "common.copy", defaultValue: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.copyableText, forType: .string)
                }
            }
        }
    }
}
