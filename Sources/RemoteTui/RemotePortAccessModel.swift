import CmuxRemoteSession
import CmuxCore
import Foundation
import Observation

/// One user-controlled SSH service route shared by its browser projections.
@MainActor
@Observable
final class RemotePortAccessModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case stopping
        case direct
        case proxied(RemoteBrowserProxyEndpoint)
        case forwarded(UInt16)
        case failed(String)
        case closed
    }

    private(set) var target: RemotePortForwardTarget
    private(set) var phase: Phase = .idle
    let route: RemotePortAccessRoute
    private let wake: @MainActor () async throws -> Void
    private let startForward: @MainActor (RemotePortForwardTarget) async throws -> UInt16
    private let stopForward: @MainActor () async -> Void
    private let startBrowserProxy: (@MainActor () async throws -> RemoteBrowserProxyEndpoint)?
    /// Browser-proxy routes can retain a guest-local origin (for example
    /// `https://localhost:8443`). Raw loopback forwards rewrite the origin to
    /// an HTTP listener, but the proxy preserves TLS and the original host.
    private let preservesRemoteHost: Bool
    var usesRemoteNetwork: Bool { route == .remoteBrowser }
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(
        target: RemotePortForwardTarget,
        wake: @escaping @MainActor () async throws -> Void,
        startForward: @escaping @MainActor (RemotePortForwardTarget) async throws -> UInt16,
        stopForward: @escaping @MainActor () async -> Void,
        route: RemotePortAccessRoute = .loopback,
        startBrowserProxy: (@MainActor () async throws -> RemoteBrowserProxyEndpoint)? = nil,
        preservesRemoteHost: Bool = false
    ) {
        self.target = target
        self.wake = wake
        self.startForward = startForward
        self.stopForward = stopForward
        self.route = startBrowserProxy == nil || route == .remoteBrowser ? route : .browserProxy
        self.startBrowserProxy = startBrowserProxy
        self.preservesRemoteHost = preservesRemoteHost
    }

    var failureMessage: String? {
        switch phase {
        case .failed(let message): return message
        case .closed: return String(localized: "cloud.ports.closed", defaultValue: "Closed")
        default: return nil
        }
    }

    var isReady: Bool {
        switch phase { case .direct, .forwarded, .proxied: return true; default: return false }
    }

    var browserProxy: RemoteBrowserProxyEndpoint? {
        if case .proxied(let endpoint) = phase { return endpoint }
        return nil
    }

    var usesBrowserProxy: Bool { route == .browserProxy || route == .remoteBrowser }

    func connectBrowser(force: Bool = false) {
        if force { retry() } else { connect() }
    }

    var localAddress: String? {
        guard case .forwarded(let port) = phase else { return nil }
        return "127.0.0.1:\(port)"
    }


    func updateTarget(_ newTarget: RemotePortForwardTarget) {
        guard target != newTarget, phase != .closed else { return }
        target = newTarget
        retry()
    }

    /// Every materialization, restore, and address-bar open uses this action.
    /// Reusing a model cannot restart an in-flight or established connection.
    func connect() {
        guard phase == .idle else { return }
        start()
    }

    func retry() {
        guard phase != .closed, phase != .stopping else { return }
        start()
    }

    private func start() {
        switch route {
        case .direct:
            run { .direct }
        case .browserProxy, .remoteBrowser:
            guard let startBrowserProxy else { return }
            run { [wake] in
                try await wake()
                try Task.checkCancellation()
                return .proxied(try await startBrowserProxy())
            }
        case .loopback:
            run { [wake, startForward, target] in
                try await wake()
                try Task.checkCancellation()
                return .forwarded(try await startForward(target))
            }
        }
    }

    func stop() async {
        guard phase != .closed, phase != .stopping else { return }
        generation += 1
        operation?.cancel()
        let pending = operation
        operation = nil
        phase = .stopping
        let token = generation
        await pending?.value
        if route == .loopback { await stopForward() }
        guard phase != .closed, generation == token else { return }
        phase = .idle
    }

    func retire() async {
        generation += 1
        let pending = operation
        phase = .closed
        operation?.cancel()
        operation = nil
        await pending?.value
        if route == .loopback { await stopForward() }
    }

    func url(for remoteURL: URL) -> URL? {
        switch phase {
        case .direct: return remoteURL
        case .proxied where preservesRemoteHost:
            // WebKit bypasses its CONNECT proxy for literal loopback hosts.
            // Use the cmux alias only on the wire; RemoteBrowserAccessState maps
            // the committed URL back to the guest's localhost origin for the
            // address bar and session snapshot.
            guard remoteURL.scheme?.lowercased() == "http",
                  RemoteLoopbackProxyAlias.isLoopbackHost(remoteURL.host ?? ""),
                  var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
            else { return remoteURL }
            components.host = RemoteLoopbackProxyAlias.aliasHost
            return components.url ?? remoteURL
        case .proxied: return RemotePortRoutePolicy().privateURL(remoteURL.absoluteString, address: target.host)
        case .forwarded(let port): return RemotePortRoutePolicy().localURL(rewriting: remoteURL.absoluteString, toLoopbackPort: port)
        default: return nil
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Phase) {
        generation += 1
        let token = generation
        let previous = operation
        previous?.cancel()
        phase = .connecting
        operation = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let phase = try await action()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.phase = phase
                self.operation = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.phase = .failed(RemoteMachineLink.errorText(error))
                self.operation = nil
            }
        }
    }
}
