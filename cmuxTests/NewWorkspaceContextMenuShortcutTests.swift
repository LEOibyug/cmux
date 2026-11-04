import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Local workspace plus-menu rows and their live shortcut hints.
@MainActor
@Suite(.serialized, .exclusiveAppContext)
final class NewWorkspaceContextMenuShortcutTests {
    private var originalFileStore: KeyboardShortcutSettingsFileStore?
    private var originalBrowserDisabled: Any?

    init() {
        originalFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "new-workspace-context-menu")
        let defaults = UserDefaults.standard
        originalBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
    }

    // Explicit cleanup keeps shared settings restored before the serialized test finishes.
    private func restoreState() {
        KeyboardShortcutSettings.resetShortcut(for: .newTab)
        if let originalFileStore {
            KeyboardShortcutSettings.settingsFileStore = originalFileStore
        }
        let defaults = UserDefaults.standard
        if let originalBrowserDisabled {
            defaults.set(originalBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
        } else {
            defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
        }
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
    }

    @Test func testBuiltInActionResolvesFromConfigAndMapsToShortcut() {
        defer { restoreState() }
        #expect(CmuxSurfaceTabBarBuiltInAction.newWorkspace.shortcutAction == .newTab)
        #expect(CmuxSurfaceTabBarBuiltInAction.newTerminal.shortcutAction == .newSurface)
        #expect(CmuxSurfaceTabBarBuiltInAction.newBrowser.shortcutAction == .openBrowser)
    }

    // MARK: Plus menu

    private func loadStore(globalJSON: String) throws -> (store: CmuxConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-new-workspace-context-menu-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("cmux.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return (store, root)
    }

    private func builtInMenuRows(_ menu: NSMenu) -> [(action: CmuxSurfaceTabBarBuiltInAction, item: NSMenuItem)] {
        menu.items.compactMap { item in
            guard let box = item.representedObject as? NewWorkspaceContextMenuActionBox,
                  case .builtIn(let builtIn) = box.action.action else { return nil }
            return (builtIn, item)
        }
    }

    private func withDefaultPlusMenu<T>(_ body: (NSMenu) throws -> T) throws -> T {
        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!store.newWorkspaceContextMenuIsConfigured)
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: store
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: store
        ))
        return try body(menu)
    }

    @Test func testDefaultPlusMenuListsStandardRowsWithShortcutHints() throws {
        defer { restoreState() }
        try withDefaultPlusMenu { menu in
            let rows = builtInMenuRows(menu)
            let leading = rows.prefix(3).map(\.action)
            #expect(leading == [.newWorkspace, .newTerminal, .newBrowser])

            let hints = Dictionary(uniqueKeysWithValues: rows.map { ($0.action, $0.item) })
            #expect(hints[.newWorkspace]?.keyEquivalent == "n")
            #expect(hints[.newWorkspace]?.keyEquivalentModifierMask == [.command])
            #expect(hints[.newTerminal]?.keyEquivalent == "t")
            #expect(hints[.newTerminal]?.keyEquivalentModifierMask == [.command])
            #expect(hints[.newBrowser]?.keyEquivalent == "l")
            #expect(hints[.newBrowser]?.keyEquivalentModifierMask == [.command, .shift])
        }
    }

    @Test func testPlusMenuHintFollowsRebindAndUnbind() throws {
        defer { restoreState() }
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: true, option: false, control: false),
            for: .newTab
        )
        try withDefaultPlusMenu { menu in
            let item = try #require(builtInMenuRows(menu).first { $0.action == .newWorkspace }?.item)
            #expect(item.keyEquivalent == "k")
            #expect(item.keyEquivalentModifierMask == [.command, .shift])
        }

        KeyboardShortcutSettings.setShortcut(.unbound, for: .newTab)
        try withDefaultPlusMenu { menu in
            let item = try #require(builtInMenuRows(menu).first { $0.action == .newWorkspace }?.item)
            #expect(item.keyEquivalent == "")
            #expect(item.keyEquivalentModifierMask == [])
        }
    }

    @Test func testPlusMenuHidesBrowserRowWhenBrowserIsDisabled() throws {
        defer { restoreState() }
        UserDefaults.standard.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        try withDefaultPlusMenu { menu in
            let actions = builtInMenuRows(menu).map(\.action)
            #expect(!actions.contains(.newBrowser))
            #expect(actions.prefix(2).map { $0 } == [.newWorkspace, .newTerminal])
        }
    }

    @Test func testConfiguredMenuKeepsUserOrderAndStillShowsHints() throws {
        defer { restoreState() }
        let (store, root) = try loadStore(globalJSON: """
        {
          "ui": { "newWorkspace": { "contextMenu": ["cmux.newTerminal", "newWorkspace"] } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.configurationIssues.isEmpty)
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: store
        ))
        let rows = builtInMenuRows(menu)
        #expect(rows.prefix(2).map(\.action) == [.newTerminal, .newWorkspace])
        let workspaceRow = try #require(rows.dropFirst().first)
        #expect(workspaceRow.item.keyEquivalent == "n")
    }

#if DEBUG
    @Test func testCommandNRoutesToLocalWorkspace() throws {
        defer { restoreState() }
        let windowFixture = NewWorkspaceShortcutWindowFixture(); defer { windowFixture.cleanup() }
        let appDelegate = windowFixture.appDelegate
        let manager = windowFixture.tabManager
        let originalCount = manager.tabs.count
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowFixture.window.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45 // kVK_ANSI_N
        ))

        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(manager.tabs.count == originalCount + 1)
    }

#endif
}
