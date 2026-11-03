public import CryptoKit
public import Foundation
public import Network
public import WebKit

/// Browser identity and networking stay separate: an HTTP CONNECT proxy never changes the document URL.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public struct RemoteBrowserRouting: Sendable {

    public static func storeID(panelID: UUID, profileID: UUID, machineID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("ssh-browser:\(panelID):\(profileID):\(machineID)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func configuration(endpoint: RemoteBrowserProxyEndpoint, address: String, remoteNetwork: Bool = false) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!))
        proxy.applyCredential(username: endpoint.username, password: endpoint.password)
        // An empty list means all domains. An array containing an empty string
        // is not a wildcard and causes WebKit to bypass the proxy.
        proxy.matchDomains = remoteNetwork ? [] : [address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))]
        proxy.allowFailover = false
        return proxy
    }

    /// Replace credentials as one script registration. An old document-start
    /// script must never win its installation guard after a carrier reconnect.
    @MainActor
    public static func installWebSocketBridge(endpoint: RemoteBrowserProxyEndpoint, address: String, on webView: WKWebView, remoteNetwork: Bool = false) {
        let controller = webView.configuration.userContentController
        let retained = controller.userScripts.filter { !$0.source.contains("window.__cmuxRemoteWebSocketBridgeInstalled") }
        controller.removeAllUserScripts()
        for script in retained { controller.addUserScript(script) }
        if let source = websocketBridgeScript(endpoint: endpoint, address: address, remoteNetwork: remoteNetwork) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// Installs the promptless WebSocket bridge used by WKWebView, whose page
    /// WebSocket implementation does not consistently honor `proxyConfigurations`.
    @MainActor
    static func websocketBridgeScript(endpoint: RemoteBrowserProxyEndpoint, address: String, remoteNetwork: Bool = false) -> String? {
        guard let token = endpoint.websocketToken else { return nil }
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let encodedHost = host.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let encodedToken = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          if (window.__cmuxRemoteWebSocketBridgeInstalled) return;
          const targetHost = '\(encodedHost)'.toLowerCase();
          const token = '\(encodedToken)';
          const NativeWebSocket = window.WebSocket;
          if (typeof NativeWebSocket !== 'function') return;
          window.__cmuxRemoteWebSocketBridgeInstalled = true;
          const rewrite = (input) => {
            let parsed;
            try { parsed = new URL(input, document.baseURI); } catch (_) { return null; }
            // Keep wss:// on WebKit's native CONNECT path. Rewriting it to ws://
            // would downgrade TLS and make the upstream handshake invalid.
            if (parsed.protocol !== 'ws:' || (!\(remoteNetwork ? "true" : "false") && parsed.hostname.toLowerCase() !== targetHost)) return null;
            const target = `${parsed.hostname}:${parsed.port || '80'}`;
            parsed.protocol = 'ws:';
            parsed.hostname = '127.0.0.1';
            parsed.port = String(\(endpoint.port));
            parsed.pathname = '/__cmux_ws__/' + target + parsed.pathname;
            return parsed.href;
          };
          window.__cmuxRemoteWebSocketBridgeRewrite = rewrite;
          const originalURLs = new WeakMap();
          const CmuxWebSocket = class extends NativeWebSocket {
            constructor(input, protocols) {
            const rewritten = rewrite(input);
            if (!rewritten) { super(input, protocols); return; }
            const values = protocols === undefined ? [] : (typeof protocols === 'string' ? [protocols] : Array.from(protocols));
            const auth = 'cmux-proxy-' + token;
            if (!values.includes(auth)) values.push(auth);
            super(rewritten, values);
            originalURLs.set(this, new URL(input, document.baseURI).href);
            }
            get url() { return originalURLs.get(this) || super.url; }
          };
          window.__cmuxRemoteWebSocketBridgeConstructor = CmuxWebSocket;
          window.WebSocket = CmuxWebSocket;
        })();
        """
    }

    /// Favicons use the page's authenticated browser route and cookies, rather than the OS network.
    @MainActor
    public static func favicon(url: URL, webView: WKWebView) async throws -> (Data, URLResponse) {
        let result = try await webView.callAsyncJavaScript("""
            const response = await fetch(url, {signal: AbortSignal.timeout(2000)});
            if (!response.ok || Number(response.headers.get('content-length')) > 2097152) throw new Error('Icon unavailable');
            const reader = response.body.getReader();
            let text = '', length = 0;
            while (true) {
              const {done, value} = await reader.read();
              if (done) break;
              length += value.length;
              if (length > 2097152) { await reader.cancel(); throw new Error('Icon too large'); }
              for (let i = 0; i < value.length; i += 8192) text += String.fromCharCode(...value.subarray(i, i + 8192));
            }
            return {data: btoa(text), status: response.status, type: response.headers.get('content-type') || ''};
            """, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        guard let value = result as? [String: Any], let encoded = value["data"] as? String,
              let data = Data(base64Encoded: encoded), let status = value["status"] as? Int,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": value["type"] as? String ?? ""]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    public init() {}
}
