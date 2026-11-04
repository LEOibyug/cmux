import AppKit
import CmuxRemoteSession
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud workspace targeting", .serialized, .exclusiveAppContext)
struct CloudWorkspaceTargetingTests {

    @Test("A captured projection host creates in its original window without changing selection")
    func projectionOwnership() throws {
        let owner = TabManager()
        let other = TabManager()
        defer { owner.finalizeAllWorkspacesForWindowClose(); other.finalizeAllWorkspacesForWindowClose() }
        let original = owner.selectedTabId
        let otherIDs = other.tabs.map(\.id)
        let host = SurfaceCatalog.NewWorkspaceHost(tabManager: owner)
        let created = try host.create("Cloud workspace", false)
        #expect(owner.workspacesById[created.workspaceID] != nil)
        #expect(owner.selectedTabId == original)
        #expect(other.tabs.map(\.id) == otherIDs)
        owner.finalizeAllWorkspacesForWindowClose()
        #expect(throws: CancellationError.self) { try host.create("Late workspace", false) }
    }


    @Test("A late SSH creation preserves newer workspace navigation", arguments: [false, true])
    func completionFocus(navigate: Bool) async throws {
        let fixture = try TuiWorkspaceCreationSidebarFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let local = try #require(manager.selectedWorkspace)
        let other = try #require(manager.addWorkspaceIfActive(initialSurface: .remoteLoading, select: false))
        let window = KeyStatusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        manager.window = window
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        fixture.provider.usesReceipt = true
        let entered = RemoteLinkFirstValue<Bool>()
        let release = RemoteLinkFirstValue<Bool>()
        fixture.provider.beforeCreate = {
            entered.resolve(true)
            _ = await release.result
        }
        let creation = Task { @MainActor in try await fixture.create(focus: true) }
        #expect(await entered.result == true)
        if navigate { manager.selectWorkspace(other) }
        release.resolve(true)
        let result = try await creation.value
        let created = try #require(result.opened?.workspaceID)
        #expect(manager.selectedTabId == (navigate ? other.id : created))
        #expect(manager.workspacesById[local.id] != nil)
    }


}
