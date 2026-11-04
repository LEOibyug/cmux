import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarNewLocalWorkspaceTests {

    @Test func plusMenuCreatesLocalAndAdvertisesCommandN() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        let originalCount = fixture.manager.tabs.count

        try fixture.clickNewWorkspace()

        #expect(fixture.manager.tabs.count == originalCount + 1)
        let created = try #require(fixture.manager.selectedWorkspace)
        #expect(created.id != selected.id)
        #expect(created.remoteWorkspaceBinding == nil)
        #expect(created.remoteConfiguration == nil)
    }

    @Test func plusMenuDoesNotInheritDirectoryFromSSHBinding() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        selected.currentDirectory = "/remote-only/project"
        selected.remoteWorkspaceBinding = RemoteWorkspaceBinding(
            machineID: "ssh:" + String(repeating: "a", count: 64)
        )

        try fixture.clickNewWorkspace()

        let created = try #require(fixture.manager.selectedWorkspace)
        #expect(created.remoteWorkspaceBinding == nil)
        #expect(created.currentDirectory == fixture.root.path)
    }

    @Test func commandNPreservesLocalDirectoryInheritanceAndGroupPlacement() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        selected.currentDirectory = nested.path
        let groupID = try #require(fixture.manager.createWorkspaceGroup(
            name: "Local Cmd-N",
            childWorkspaceIds: [selected.id]
        ))

        #expect(fixture.app.performNewLocalWorkspaceAction(
            tabManager: fixture.manager,
            debugSource: "test.local.group"
        ))
        let created = try #require(fixture.manager.selectedWorkspace)
        #expect(created.groupId == groupID)
        #expect(created.currentDirectory == nested.path)
    }


    @Test func commandNWithoutAWindowKeepsTheInitialWorkspace() throws {
        let app = AppDelegate()
        #expect(app.mainWindowContexts.isEmpty)
        #expect(app.performNewLocalWorkspaceAction(debugSource: "test.local.noWindow"))
        let context = try #require(app.mainWindowContexts.first?.value)
        defer {
            context.tabManager.tabs.forEach { $0.teardownAllPanels() }
            app.unregisterMainWindowContextForTesting(windowId: context.windowId)
            app.forgetRecoverableMainWindowRoute(windowId: context.windowId)
        }
        #expect(context.tabManager.tabs.count == 1)
        #expect(context.tabManager.selectedWorkspace?.remoteWorkspaceBinding == nil)
    }
}

private extension SidebarNewLocalWorkspaceTests {
    @MainActor
    final class Fixture {
        let app = AppDelegate()
        let manager: TabManager
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let store: CmuxConfigStore
        let windowID: UUID

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("cmux.json")
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            let defaultsSuite = "SidebarNewLocalWorkspaceTests.\(UUID().uuidString)"
            suiteName = defaultsSuite
            defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            store = CmuxConfigStore(globalConfigPath: config.path, localConfigPath: nil, startFileWatchers: false)
            store.loadAll()
            let localDirectory = root.path
            manager = TabManager(
                initialWorkingDirectory: localDirectory,
                settings: UserDefaultsSettingsClient(defaults: defaults),
                defaultWorkspaceWorkingDirectoryProvider: { localDirectory }
            )
            windowID = app.registerMainWindowContextForTesting(tabManager: manager, cmuxConfigStore: store)
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowID })
            context.window = window
        }

        func clickNewWorkspace() throws {
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowID })
            let menu = try #require(app.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
            let index = try #require(menu.items.firstIndex {
                ($0.representedObject as? NewWorkspaceContextMenuActionBox)?.action.action == .builtIn(.newWorkspace)
            })
            let item = menu.items[index]
            #expect(item.title == String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"))
            #expect(item.keyEquivalent == "n")
            #expect(item.keyEquivalentModifierMask == [.command])
            menu.performActionForItem(at: index)
        }

        func tearDown() {
            manager.tabs.forEach { $0.teardownAllPanels() }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
