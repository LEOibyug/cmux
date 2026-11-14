import AppKit
import SwiftUI

@MainActor
final class ControlCenterWindowController: ReleasingWindowController {
    static let shared = ControlCenterWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.controlCenter")
        window.title = ControlCenterStrings.text("title")
        window.setFrameAutosaveName("cmux.controlCenter")
        window.contentView = NSHostingView(rootView: ControlCenterView(coordinator: .shared))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        window.center()
        return window
    }

    func show(activate: Bool = false) {
        let window = managedWindow()
        if activate {
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        } else {
            window.orderFront(nil)
        }
    }
}
