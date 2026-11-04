import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation
import CmuxCore
import CmuxFoundation
import Observation
import OSLog

private let tuiDisplayLogger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteBrowserNavigation")

/// Browser-owned navigation state, separate from the shared SSH port choice.
/// Failed loads keep the native connection controls visible in the same pane.
@MainActor
@Observable
final class RemoteBrowserAccessState {
    var model: RemotePortAccessModel?
    private(set) var resourceID: SurfaceResourceID?
    private(set) var remoteURL: URL?
    private(set) var navigationURL: URL?
    private(set) var hasCommittedNavigation = false
    private(set) var loaded = false
    private(set) var error: String?
    private var dismissedFailure: String?
    var showsPorts = true
    private(set) var unavailable: String?
    private(set) var isRestoring = false
    /// Set while the pane waits for its resource to exist (a guest display
    /// still starting). Any route or failure replaces it.
    private(set) var starting: String?
    private var unavailableRetry: (@MainActor (UInt64) async -> Void)?
    private var unavailableRetryTask: Task<Void, Never>?
    private var unavailableRetryGeneration: UInt64 = 0
    @ObservationIgnored private let restoreDeadline: MainActorDeferredActionScheduler
    /// Set while the unavailable card belongs to a session restore, so its
    /// retry returns to the restoring state instead of a static card.
    @ObservationIgnored private var restoreFailureMessage: String?
    @ObservationIgnored private var restoreDeadlineDuration: Duration = .seconds(30)
    @ObservationIgnored private var navigate: (@MainActor (URL) -> Void)?
    @ObservationIgnored private var navigateRequest: (@MainActor (URLRequest) -> Void)?
    @ObservationIgnored private var pendingNavigationRequest: URLRequest?
    @ObservationIgnored private var retiredListenerURLs: [URL] = []
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var preservingCommittedRoute = false
    private var activeNavigationID: ObjectIdentifier?
    @ObservationIgnored private let logID = UUID().uuidString
    @ObservationIgnored private var attempt = 0
    /// Quiet retries for a route's first desktop connection. noVNC gives up
    /// after an initial connect failure (its own reconnect only follows a
    /// session that once connected), and a restored or new display can lose
    /// that race while its proxy or guest listener is still starting.

    init(clock: any Clock<Duration> = ContinuousClock()) {
        restoreDeadline = MainActorDeferredActionScheduler(clock: clock)
    }


    /// Route readiness belongs to the browser, including while its SwiftUI host
    /// is hidden. Observe the current value again after every transition so a
    /// cached retry cannot lose a connecting → ready change to view coalescing.
    func automaticallyNavigate(_ action: @escaping @MainActor (URL) -> Void) {
        navigate = action
        navigateRequest = nil
        observeRoute()
    }

    /// Installs a readiness callback that preserves the complete request,
    /// including its method, headers, and body, while replacing only its URL
    /// with the local SSH listener.
    func automaticallyNavigateRequest(_ action: @escaping @MainActor (URLRequest) -> Void) {
        navigateRequest = action
        navigate = nil
        observeRoute()
    }

    /// Rebinds ownership to a committed same-host service without restarting the
    /// current WebKit navigation (for example, a POST redirect to another port).
    func adoptCommittedRoute(model: RemotePortAccessModel, url: URL, resourceID: SurfaceResourceID) {
        let logicalURL = Self.canonicalLoopbackURL(url, for: model)
        observationGeneration &+= 1
        cancelUnavailableRetry()
        unavailable = nil
        isRestoring = false
        restoreFailureMessage = nil
        self.resourceID = resourceID
        self.model = model
        starting = nil
        remoteURL = logicalURL
        // WebKit has already committed this URL. Retain that identity so the
        // delegate's finish/desktop callbacks are accepted without issuing a
        // second request after a same-host redirect.
        navigationURL = logicalURL
        hasCommittedNavigation = true
        preservingCommittedRoute = true
        loaded = false
        error = nil
        dismissedFailure = nil
        trace("route_adopted")
        observeRoute()
    }

    func retainResource(_ resource: SurfaceResourceID) { resourceID = resource }

    private func observeRoute() {
        observationGeneration &+= 1
        let generation = observationGeneration
        guard let model, navigate != nil || navigateRequest != nil else { return }
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.observeRoute()
            }
        }
        if preservingCommittedRoute {
            // The new model may still be acquiring its proxy. Keep the URL and
            // committed-document identity stable until it is ready; adoption
            // must never replay a request WebKit already committed.
            if model.isReady { preservingCommittedRoute = false }
            return
        }
        if let request = nextRequest() {
            if let navigateRequest { navigateRequest(request) }
            else if let url = request.url { navigate?(url) }
        }
    }

    private func trace(_ event: String) {
        tuiDisplayLogger.debug("Browser route: id=\(self.logID, privacy: .public) attempt=\(self.attempt) event=\(event, privacy: .public) ready=\(self.model?.isReady == true) committed=\(self.hasCommittedNavigation) loaded=\(self.loaded)")
    }


    func showStarting(_ message: String) {
        leave()
        starting = message
    }

    func showUnavailable(_ message: String, retry: (@MainActor (UInt64) async -> Void)? = nil) {
        let retainedResource = resourceID
        leave()
        resourceID = retainedResource
        unavailable = message
        unavailableRetry = retry
    }

    /// Session restore is recoverable while the provider and resource graph
    /// are being rebuilt. Keep that phase separate from a terminal failure:
    /// progress stays visible until the route configures, the provider
    /// reports a settled miss (``failRestore(_:)``), or `deadline` passes.
    func showRestoring(
        retry: @escaping @MainActor (UInt64) async -> Void,
        unavailableMessage: String,
        deadline: Duration = .seconds(30)
    ) {
        // A retry that finds the restore still pending keeps the original
        // deadline instead of extending the loading state indefinitely.
        if isRestoring {
            unavailableRetry = retry
            return
        }
        let retainedResource = resourceID
        leave()
        resourceID = retainedResource
        isRestoring = true
        unavailableRetry = retry
        restoreFailureMessage = unavailableMessage
        restoreDeadlineDuration = deadline
        scheduleRestoreDeadline()
    }

    private func scheduleRestoreDeadline() {
        guard let message = restoreFailureMessage else { return }
        restoreDeadline.schedule(after: restoreDeadlineDuration) { [weak self] in
            self?.failRestore(message)
        }
    }

    /// Ends the restore phase with a recoverable card. The retry action stays
    /// installed so the card can start another restore attempt.
    func failRestore(_ message: String) {
        guard isRestoring else { return }
        unavailableRetryTask?.cancel()
        unavailableRetryTask = nil
        unavailableRetryGeneration &+= 1
        restoreDeadline.cancel()
        isRestoring = false
        unavailable = message
    }

    func retryUnavailable() {
        guard unavailableRetryTask == nil, let unavailableRetry else { return }
        if unavailable != nil, restoreFailureMessage != nil {
            unavailable = nil
            isRestoring = true
            scheduleRestoreDeadline()
        }
        unavailableRetryGeneration &+= 1
        let generation = unavailableRetryGeneration
        unavailableRetryTask = Task { @MainActor [weak self] in
            await unavailableRetry(generation)
            guard let self, !Task.isCancelled, self.unavailableRetryGeneration == generation else { return }
            self.unavailableRetryTask = nil
        }
    }

    func isCurrentUnavailableRetry(_ generation: UInt64) -> Bool {
        unavailableRetryGeneration == generation
            && (unavailable != nil || isRestoring)
            && !Task.isCancelled
    }

    var unavailableRetryAction: (() -> Void)? {
        guard unavailableRetry != nil else { return nil }
        return { [weak self] in self?.retryUnavailable() }
    }

    var showsPage: Bool { model?.isReady == true && loaded && error == nil }

    /// A remote document can commit before its render-blocking resources arrive.
    /// Use the pane's backing color through that initial load for every origin;
    /// after load WebKit resumes its ordinary document background semantics.
    var isPreparingDocument: Bool { model != nil && !loaded && failureMessage == nil }


    var failureMessage: String? {
        if let error = error ?? unavailable { return error }
        if case .failed(let message)? = model?.phase { return message }
        return nil
    }

    /// A failed remote placeholder still owns its resource. A browser that has
    /// deliberately navigated away has called `leave()` and must duplicate its
    /// current page as an ordinary browser instead of resurrecting that stale
    /// remote projection.
    var retainsRemoteResourceForDuplication: Bool {
        model != nil || resourceID?.machine.isLocal == false
    }

    var showsFailureAlert: Bool {
        failureMessage.map { $0 != dismissedFailure } ?? false
    }

    func dismissFailure() { dismissedFailure = failureMessage }



    /// Persist the service identity; the local listener only lives for this app run.
    func sessionURL(currentURL: URL?) -> URL? {
        guard let remoteURL else { return nil }
        guard let currentURL, currentURL.scheme != "about" else { return remoteURL }
        if model?.usesRemoteNetwork == true { return displayURL(currentURL) ?? currentURL }
        guard ownsLoopbackListener(currentURL) else { return navigationURL == nil ? remoteURL : nil }
        guard var parts = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) else { return remoteURL }
        parts.host = remoteURL.host
        parts.port = remoteURL.port
        parts.scheme = remoteURL.scheme
        return parts.url ?? remoteURL
    }

    /// WebKit loads loopback forwards through an ephemeral local listener, but
    /// the browser chrome should continue to identify the remote service the
    /// user opened. Preserve the listener's path/query/fragment while swapping
    /// its transport authority back to the stable service authority.
    func displayURL(_ observedURL: URL?) -> URL? {
        guard let remoteURL else { return nil }
        if let observedURL, Self.isLoopbackAliasHost(observedURL.host ?? ""),
           observedURL.scheme?.lowercased() == "http",
           var components = URLComponents(url: observedURL, resolvingAgainstBaseURL: false) {
            components.host = RemoteLoopbackProxyAlias.isLoopbackHost(remoteURL.host ?? "")
                ? remoteURL.host : RemoteLoopbackProxyAlias.canonicalLoopbackHost
            return components.url
        }
        if model?.route == .loopback,
           let observedURL,
           observedURL.scheme?.lowercased() == "http",
           ownsLoopbackListener(observedURL),
           let logicalURL = sessionURL(currentURL: observedURL) {
            return logicalURL
        }
        // A bootstrap document belongs to WebKit, not to the user's
        // navigation. Keep the requested remote origin until a real service
        // document commits.
        guard !hasCommittedNavigation,
              observedURL == nil || observedURL?.scheme == "about" else { return nil }
        return remoteURL
    }

    /// A freshly forwarded navigation can commit before `nextRequest()` has
    /// recorded its listener as `navigationURL`. The model's current local
    /// address is authoritative during that small window, so treat that port
    /// as owned for display rewriting as well.
    private func ownsLoopbackListener(_ url: URL) -> Bool {
        guard owns(url) else {
            guard let localAddress = model?.localAddress,
                  let localPort = Int(localAddress.split(separator: ":").last ?? ""),
                  url.port == localPort,
                  PrivateNetworkHostPolicy().isLoopback(host: url.host ?? "") else {
                return false
            }
            return true
        }
        return true
    }

    func configure(model: RemotePortAccessModel, url: URL, resourceID: SurfaceResourceID? = nil,
                   request: URLRequest? = nil) {
        let logicalURL = Self.canonicalLoopbackURL(url, for: model)
        let replacesService = remoteURL.map { !Self.sameService($0, logicalURL) } ?? true
        observationGeneration &+= 1
        cancelUnavailableRetry()
        unavailable = nil
        isRestoring = false
        restoreFailureMessage = nil
        // WebView/profile replacement reconfigures the existing route without
        // passing the identity again. Keep the stable display ID until an
        // explicit replacement supplies a new one; callers that leave Cloud
        // first still clear it deliberately.
        if let resourceID {
            self.resourceID = resourceID
        }
        self.model = model
        starting = nil
        remoteURL = logicalURL
        pendingNavigationRequest = request ?? URLRequest(url: logicalURL)
        if replacesService { retiredListenerURLs.removeAll(keepingCapacity: true) }
        navigationURL = nil
        preservingCommittedRoute = false
        hasCommittedNavigation = false
        loaded = false
        error = nil
        dismissedFailure = nil
        activeNavigationID = nil
        attempt += 1
        trace("configured")
        // Reconfiguration invalidates the previous observation generation.
        // Re-arm it even when the same access model is reused by a WebView
        // replacement that is still waiting for its route to become ready.
        observeRoute()
    }

    func nextRequest() -> URLRequest? {
        guard let remoteURL, let url = model?.url(for: remoteURL) else {
            rememberRetiredListener(navigationURL)
            hasCommittedNavigation = false
            navigationURL = nil
            loaded = false
            return nil
        }
        guard navigationURL != url else { return nil }
        rememberRetiredListener(navigationURL)
        // Keep the original request as the route's replay template. A forward
        // child can exit after readiness and be replaced on a new listener;
        // rebuilding from the URL alone would silently turn a POST into a GET
        // and drop its headers/body on that recovery path.
        var request = pendingNavigationRequest ?? URLRequest(url: url)
        request.url = url
        navigationURL = url
        hasCommittedNavigation = false
        error = nil
        dismissedFailure = nil
        loaded = false
        trace("route_ready")
        return request
    }

    /// The routed URL for callers that only need a GET navigation.
    func nextURL() -> URL? { nextRequest()?.url }

    /// Replaces the request template used if the shared forward must be
    /// recreated. BrowserPanel calls this for each new service navigation so
    /// recovery replays the current request rather than an older POST.
    func rememberNavigationRequest(_ request: URLRequest) {
        guard let url = request.url, owns(url),
              let serviceURL = sessionURL(currentURL: url) else { return }
        pendingNavigationRequest = request
        // Keep the remote authority stable when WebKit loads a local listener,
        // but carry the latest path/query/fragment into a replacement forward.
        remoteURL = serviceURL
        // This request is about to load. Retain its routed identity so delegate
        // callbacks can finish it and readiness cannot issue a duplicate load.
        navigationURL = model?.url(for: serviceURL)
    }

    /// Returns whether a loopback URL was a listener this route replaced.
    /// Other loopback ports may identify a different SSH service and must keep
    /// their own port when the browser asks to open them.
    func isRetiredListener(_ url: URL) -> Bool {
        retiredListenerURLs.contains { Self.sameService($0, url) }
    }

    private func rememberRetiredListener(_ url: URL?) {
        guard let url,
              url.scheme?.lowercased() == "http",
              PrivateNetworkHostPolicy().isLoopback(host: url.host ?? "") else { return }
        guard !retiredListenerURLs.contains(where: { Self.sameService($0, url) }) else { return }
        retiredListenerURLs.append(url)
        if retiredListenerURLs.count > 8 { retiredListenerURLs.removeFirst() }
    }

    func didStart(url: URL?, navigationID: ObjectIdentifier? = nil) {
        guard let url, navigationURL != nil else { return }
        activeNavigationID = navigationID
        guard owns(url) else { return }
        hasCommittedNavigation = false
        loaded = false
        error = nil
        dismissedFailure = nil
        trace("navigation_started")
    }

    func didCommit(url: URL?, navigationID: ObjectIdentifier? = nil) {
        guard navigationID == nil || navigationID == activeNavigationID else { return }
        guard let url, navigationURL != nil else { return }
        guard owns(url) else {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { leave() }
            return
        }
        if model?.usesBrowserProxy == true {
            remoteURL = displayURL(url) ?? url
            navigationURL = url
        }
        hasCommittedNavigation = true
        trace("navigation_committed")
    }

    func didFinish(url: URL?) {
        guard let url, navigationURL != nil, hasCommittedNavigation, owns(url), url.scheme != "about", error == nil else { return }
        loaded = true
        error = nil
        trace("navigation_finished")
    }

    func didFail(url: URL?, message: String, navigationID: ObjectIdentifier? = nil) {
        guard navigationID == nil || navigationID == activeNavigationID else { return }
        guard let url, navigationURL != nil, owns(url) else { return }
        loaded = false
        error = message
        hasCommittedNavigation = false
        activeNavigationID = nil
        trace("navigation_failed")
    }

    func didCancel(navigationID: ObjectIdentifier? = nil) {
        guard model != nil, !loaded,
              navigationID == nil || navigationID == activeNavigationID else { return }
        // Stop also applies while the shared route is still connecting. Other
        // projections can keep that route alive without restarting this pane.
        observationGeneration &+= 1
        error = String(localized: "remote.browser.connectionCancelled", defaultValue: "The SSH page connection was cancelled. Retry to connect.")
        hasCommittedNavigation = false
        activeNavigationID = nil
        trace("navigation_cancelled")
    }

    func retry() {
        attempt += 1
        trace("retry")
        // An explicit retry is a new first connection with its own quiet retries.
        rememberRetiredListener(navigationURL)
        navigationURL = nil
        preservingCommittedRoute = false
        hasCommittedNavigation = false
        loaded = false
        error = nil
        dismissedFailure = nil
        activeNavigationID = nil
        model?.retry()
        observeRoute()
    }

    func owns(_ url: URL) -> Bool {
        // A daemon browser owns its entire document session on the machine,
        // rather than one preview port. Redirects and an explicit about:blank
        // navigation therefore keep the remote resource attached to this pane;
        // port preview resources retain the stricter host/port check below.
        let ownsDaemonBrowserDocument = resourceID?.kind == .browser
            && !(resourceID?.key.hasPrefix("port:") ?? false)
            && (["http", "https"].contains(url.scheme?.lowercased() ?? "")
                || url.absoluteString.lowercased() == "about:blank")
        if ownsDaemonBrowserDocument {
            return true
        }
        guard let remoteURL else { return false }
        if model?.usesBrowserProxy == true {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  Self.browserRouteHostsMatch(url.host, remoteURL.host) else { return false }
            if let resourceID, let expectedPort = Self.resourcePort(for: resourceID) {
                let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
                return requestedPort == expectedPort
            }
            return true
        }
        return Self.sameService(url, remoteURL) || navigationURL.map { Self.sameService(url, $0) } == true
    }

    /// Explicit localhost links within a VM page keep that page's VM as their owner.
    func rewrittenLoopbackURL(_ url: URL) -> URL? {
        guard model?.usesBrowserProxy == true,
              RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? ""),
              let address = model?.target.host else { return nil }
        if model?.usesRemoteNetwork == true, url.scheme?.lowercased() == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = RemoteLoopbackProxyAlias.aliasHost
            return components?.url
        }
        if model?.route == .browserProxy,
           RemoteLoopbackProxyAlias.isLoopbackHost(address) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = address
            return components?.url
        }
        return RemotePortRoutePolicy().privateURL(url.absoluteString, address: address)
    }

    private func cancelUnavailableRetry() {
        restoreDeadline.cancel()
        unavailableRetryTask?.cancel()
        unavailableRetryTask = nil
        unavailableRetryGeneration &+= 1
        unavailableRetry = nil
    }

    func leave() {
        cancelUnavailableRetry()
        observationGeneration &+= 1
        navigate = nil
        navigateRequest = nil
        pendingNavigationRequest = nil
        retiredListenerURLs.removeAll(keepingCapacity: false)
        resourceID = nil
        activeNavigationID = nil
        hasCommittedNavigation = false
        unavailable = nil
        isRestoring = false
        restoreFailureMessage = nil
        starting = nil
        model = nil
        remoteURL = nil
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        dismissedFailure = nil
    }

    private static func sameService(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && serviceHost(a) == serviceHost(b)
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }

    private static func isLoopbackAliasHost(_ host: String) -> Bool {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            == "cmux-loopback.localtest.me"
    }

    private static func browserRouteHostsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return true }
        return isLoopbackAliasHost(lhs) && RemoteLoopbackProxyAlias.isLoopbackHost(rhs)
            || isLoopbackAliasHost(rhs) && RemoteLoopbackProxyAlias.isLoopbackHost(lhs)
    }

    /// SSH forwards are local transport, but their stable browser identity is
    /// the conventional loopback origin users type and dev servers print.
    /// Normalize all loopback spellings so detected ports opened from the
    /// sidebar display the same `localhost:<port>` URL as typed navigation.
    private static func canonicalLoopbackURL(_ url: URL, for model: RemotePortAccessModel) -> URL {
        guard model.route == .loopback,
              url.scheme?.lowercased() == "http",
              PrivateNetworkHostPolicy().isLoopback(host: url.host ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        parts.host = "localhost"
        return parts.url ?? url
    }

    /// Treat the loopback spellings accepted by SSH routing as one service
    /// identity, so a localhost redirect reuses the ready listener.
    private static func serviceHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return PrivateNetworkHostPolicy().isLoopback(host: host) ? "127.0.0.1" : host
    }

    private static func resourcePort(for resource: SurfaceResourceID) -> Int? {
        if resource.kind == .browser, resource.key.hasPrefix("port:") {
            return Int(resource.key.dropFirst("port:".count))
        }
        return nil
    }
}
