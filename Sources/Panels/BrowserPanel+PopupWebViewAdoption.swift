import Foundation
import CmuxBrowser
import WebKit

/// Profile resolution and adoption of WebKit-created popup views.
extension BrowserPanel {
    /// Resolves the requested profile, falling back to the user's default profile.
    static func resolvedProfileID(requested: UUID?) -> UUID {
        let requestedProfileID = requested ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
    }

    /// A web view WebKit asked for (`createWebViewWith`), created from its
    /// configuration so the page keeps its opener, that the next panel created
    /// for `url` adopts instead of making its own. Set and consumed within one
    /// main-actor turn by ``BrowserReplTabAttachment/adoptPopup``.
    @MainActor static var pendingPopupWebView: (url: URL, webView: CmuxWebView)?

    @MainActor static func takePendingPopupWebView(for url: URL?) -> CmuxWebView? {
        guard let pending = pendingPopupWebView, let url, pending.url == url else { return nil }
        pendingPopupWebView = nil
        return pending.webView
    }

}
