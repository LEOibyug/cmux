import CmuxRemoteSession
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercise the provider's real browser configuration path, including the
/// shared model lookup, rather than manually starting a forward in the test.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteBrowserAccessTests {
    @Test("Route readiness drives cold open and cached retry without a SwiftUI phase update")
    func automaticallyNavigatesAfterRouteReadiness() async throws {
        let ready = RemoteLinkFirstValue<Bool>()
        var starts = 0
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 6901),
            wake: {}, startForward: { _ in
                _ = await ready.result
                starts += 1
                return 46901
            }, stopForward: {}, route: .loopback)
        let state = RemoteBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        var navigations: [URL] = []
        state.automaticallyNavigate { navigations.append($0) }
        model.connect()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        #expect(navigations.isEmpty, "A slow route cannot invent a completed navigation")
        ready.resolve(true)
        #expect(await wait { navigations.count == 1 })
        let url = try #require(navigations.first)
        state.didCommit(url: url)
        state.didFinish(url: url)
        state.retry()
        #expect(await wait { starts == 2 && navigations.count == 2 })
        #expect(navigations[1] == url)
        state.leave()
        model.retry()
        #expect(await wait { starts == 3 })
        #expect(navigations.count == 2, "A retired document cannot navigate after leaving Cloud")
        await model.retire()
    }

    @Test("A saved Cloud browser URL never retains an ephemeral loopback port")
    func sessionSnapshotUsesPrivateServiceAddress() {
        let local = URL(string: "http://127.0.0.1:46901/vnc.html?path=websockify&resize=remote")!
        let remote = URL(string: "http://10.0.0.7:6901/vnc.html?path=websockify&resize=remote")!
        let browser = BrowserPanel(
            workspaceId: UUID(), initialURL: local, renderInitialNavigation: false,
            websiteDataStore: .nonPersistent()
        )
        defer { browser.close() }
        let model = RemotePortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), wake: {},
            startForward: { _ in 46_901 }, stopForward: {}, route: .loopback
        )
        browser.remoteAccess.configure(model: model, url: remote)
        #expect(browser.preferredURLStringForSessionSnapshot() == remote.absoluteString)
    }

    @Test("A forwarded SSH document keeps the logical localhost service URL")
    func forwardedDocumentDisplaysServiceURL() async throws {
        let model = RemotePortAccessModel(
            target: .init(host: "127.0.0.1", port: 4000),
            wake: {}, startForward: { _ in 51_636 }, stopForward: {}, route: .loopback
        )
        let state = RemoteBrowserAccessState()
        let service = try #require(URL(string: "http://localhost:4000/projects/123?tab=logs#tail"))
        state.configure(model: model, url: service)
        model.connect()
        #expect(await wait { model.isReady })
        let listener = try #require(state.nextURL())
        #expect(listener.absoluteString == "http://127.0.0.1:51636/projects/123?tab=logs#tail")
        state.didCommit(url: listener)
        state.didFinish(url: listener)
        #expect(state.displayURL(listener) == service)
        await model.retire()
    }

    @Test("Leaving a Cloud page clears its resource provenance")
    func leavingCloudClearsResourceIdentity() {
        let state = RemoteBrowserAccessState()
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 6901),
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .ssh("a"), kind: .browser, key: "port:6901")
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!, resourceID: display)
        #expect(state.resourceID == display)
        state.leave()
        #expect(state.resourceID == nil)
        #expect(!state.retainsRemoteResourceForDuplication)
    }

    @Test("An unavailable Cloud placeholder retains its resource for duplication")
    func unavailableCloudRetainsResourceIdentity() {
        let state = RemoteBrowserAccessState()
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 6901),
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .ssh("a"), kind: .browser, key: "port:6901")
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!, resourceID: display)
        state.showUnavailable("display unavailable")
        #expect(state.resourceID == display)
        #expect(state.retainsRemoteResourceForDuplication)
        state.leave()
        #expect(state.resourceID == nil)
    }

    @Test("A restoring Cloud pane keeps loading until its deadline, then offers Reload that loads again")
    func restoringCloudPaneLoadsUntilDeadline() async {
        let clock = CloudCommandDeadlineClock()
        let state = RemoteBrowserAccessState(clock: clock)
        var retries = 0
        state.showRestoring(retry: { _ in retries += 1 }, unavailableMessage: "unavailable", deadline: .seconds(30))
        // A retry that finds the restore still pending keeps the first deadline.
        state.showRestoring(retry: { _ in retries += 1 }, unavailableMessage: "unavailable", deadline: .seconds(30))
        #expect(state.isRestoring)
        #expect(state.unavailable == nil)
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(31))
        #expect(await wait { state.unavailable == "unavailable" })
        #expect(!state.isRestoring)
        guard let reload = state.unavailableRetryAction else {
            Issue.record("A failed restore must offer Reload")
            return
        }
        reload()
        #expect(state.isRestoring)
        #expect(state.unavailable == nil)
        #expect(await wait { retries == 1 })
        state.leave()
    }

    @Test("A settled restore miss shows Reload immediately, and a configured route cancels the deadline")
    func restoringCloudPaneSettles() async {
        let clock = CloudCommandDeadlineClock()
        let state = RemoteBrowserAccessState(clock: clock)
        state.showRestoring(retry: { _ in }, unavailableMessage: "unavailable")
        state.failRestore("not listening")
        #expect(state.unavailable == "not listening")
        #expect(state.unavailableRetryAction != nil)

        let restored = RemoteBrowserAccessState(clock: clock)
        restored.showRestoring(retry: { _ in }, unavailableMessage: "unavailable")
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 3400),
            wake: {}, startForward: { _ in 43400 }, stopForward: {}, route: .loopback)
        restored.configure(model: model, url: URL(string: "http://10.0.0.7:3400/")!)
        #expect(!restored.isRestoring)
        clock.advance(by: .seconds(31))
        await Task.yield()
        #expect(restored.unavailable == nil)
        state.leave()
        restored.leave()
        await model.retire()
    }

    @Test("Leaving Cloud for an external page drops stale session provenance")
    func externalNavigationDropsCloudSessionResource() {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 6902),
            wake: {}, startForward: { _ in 46902 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .ssh("a"), kind: .browser, key: "port:6902")
        browser.remoteAccess.configure(model: model, url: URL(string: "http://10.0.0.7:6902/vnc.html")!, resourceID: display)
        #expect(browser.remoteResourceForSession == display)
        browser.leaveRemoteResourceForLocalNavigation()
        #expect(browser.remoteResourceForSession == nil)
    }

    @Test("A delayed Cloud restore keeps the saved path and query")
    func delayedCloudRestoreKeepsSavedURL() throws {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        browser.pendingRemoteRestoreURL = try #require(URL(string: "http://10.0.0.7:8000/projects/123?tab=logs#tail"))
        let target = try #require(URL(string: "http://10.0.0.7:8000/"))
        #expect(browser.remoteRestoreURL(on: target).absoluteString == "http://10.0.0.7:8000/projects/123?tab=logs#tail")
    }


    @Test("A browser Cloud resource cannot retain ownership after its service port changes")
    func browserResourceOwnsOnlyItsPort() throws {
        let endpoint = RemoteBrowserProxyEndpoint(host: "127.0.0.1", port: 48000, username: "u", password: "p")
        let model = RemotePortAccessModel(target: .init(host: "10.0.0.7", port: 3000),
            wake: {}, startForward: { _ in 47000 }, stopForward: {},
            startBrowserProxy: { endpoint })
        let state = RemoteBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:3000/")!,
                        resourceID: SurfaceResourceID(machine: .ssh("a"), kind: .browser, key: "port:3000"))
        #expect(state.owns(try #require(URL(string: "http://10.0.0.7:3000/"))))
        #expect(!state.owns(try #require(URL(string: "http://10.0.0.7:8000/"))))
    }

    @Test("A daemon browser keeps its machine ownership across document navigation")
    func daemonBrowserRetainsOwnershipAcrossHostsAndAboutBlank() throws {
        let model = RemotePortAccessModel(
            target: .init(host: "10.0.0.7", port: 3000),
            wake: {}, startForward: { _ in 47000 }, stopForward: {}, route: .remoteBrowser
        )
        let state = RemoteBrowserAccessState()
        state.configure(
            model: model,
            url: URL(string: "https://public.example.test/start")!,
            resourceID: SurfaceResourceID(machine: .ssh("a"), kind: .browser, key: "browser_daemon")
        )
        #expect(state.owns(try #require(URL(string: "https://redirect.example.test/next"))))
        #expect(state.owns(try #require(URL(string: "about:blank"))))
    }

    private func wait(timeout: Int = 5, _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        return predicate()
    }

}
