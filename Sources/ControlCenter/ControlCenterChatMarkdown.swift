import AppKit
import CmuxControlCenter
import SwiftUI
import WebKit

struct ControlCenterChatMarkdown: NSViewRepresentable {
    let turns: [ControlCenterChatTurn]
    let activeTurnID: UUID?
    let liveResponse: String
    let liveOperation: ControlCenterOperation?
    let liveError: String?
    let isRunning: Bool
    let standaloneError: String?
    let isAwaitingApproval: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "controlCenterChat")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel(ControlCenterStrings.text("chatTranscriptLabel"))
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.shellHTML(), baseURL: nil)
        return webView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let payload = TranscriptPayload(
            turns: turns.map { turn in
                let active = turn.id == activeTurnID
                return TurnPayload(
                    id: turn.id.uuidString,
                    prompt: turn.prompt,
                    response: active ? liveResponse : turn.response,
                    operation: active ? liveOperation : turn.operation,
                    error: active ? liveError : turn.error,
                    working: active && isRunning
                )
            },
            error: standaloneError,
            dark: colorScheme == .dark,
            strings: [
                "you": ControlCenterStrings.text("chatYou"),
                "assistant": ControlCenterStrings.text("chatAssistant"),
                "working": ControlCenterStrings.text(isAwaitingApproval ? "chatApprovalNeeded" : "chatWorking"),
                "receipt": ControlCenterStrings.text("chatReceipt"),
                "copy": ControlCenterStrings.text("chatCopyCode"),
                "success": ControlCenterStrings.text("success"),
                "failed": ControlCenterStrings.text("failed"),
                "blocked": ControlCenterStrings.text("blocked"),
                "cancelled": ControlCenterStrings.text("cancelled")
            ]
        )
        context.coordinator.update(payload)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "controlCenterChat")
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    fileprivate struct TurnPayload: Encodable, Equatable {
        let id: String
        let prompt: String
        let response: String
        let operation: ControlCenterOperation?
        let error: String?
        let working: Bool
    }

    fileprivate struct TranscriptPayload: Encodable, Equatable {
        let turns: [TurnPayload]
        let error: String?
        let dark: Bool
        let strings: [String: String]
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var isReady = false
        private var isScheduled = false
        private var latest: TranscriptPayload?
        private var pending: TranscriptPayload?
        private var failureLabel: NSTextField?

        fileprivate func update(_ payload: TranscriptPayload) {
            guard latest != payload else { return }
            latest = payload
            pending = payload
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard isReady, !isScheduled, pending != nil else { return }
            isScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
                guard let self else { return }
                self.isScheduled = false
                guard let payload = self.pending, let webView = self.webView else { return }
                self.pending = nil
                do {
                    let data = try JSONEncoder().encode(payload)
                    let json = String(decoding: data, as: UTF8.self)
                    webView.evaluateJavaScript("window.cmuxChat.update(\(json));") { [weak self] _, error in
                        if let error { self?.showFailure(error.localizedDescription) }
                    }
                } catch {
                    self.showFailure(error.localizedDescription)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            scheduleUpdate()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showFailure(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            showFailure(ControlCenterStrings.text("chatRendererUnavailable"))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if !isReady, navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
               url.host != nil {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: String],
                  body["action"] == "copy", let code = body["text"] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }

        private func showFailure(_ detail: String) {
            guard let webView, failureLabel == nil else { return }
            let label = NSTextField(wrappingLabelWithString: "\(ControlCenterStrings.text("chatRendererUnavailable"))\n\(detail)")
            label.isSelectable = true
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            webView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: webView.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: webView.topAnchor, constant: 24)
            ])
            failureLabel = label
        }
    }

    private static func shellHTML() -> String {
        let assets = MarkdownViewerAssets.shared
        let nonce = UUID().uuidString
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(assets.lazyAsset(name: "github-markdown", ext: "css"))</style>
        <style id="highlight-light">\(assets.lazyAsset(name: "highlight-github", ext: "css"))</style>
        <style id="highlight-dark" media="not all">\(assets.lazyAsset(name: "highlight-github-dark", ext: "css"))</style>
        <style>
        :root { color-scheme: light; --fg:#202124; --muted:#707078; --line:#dedee3; --user:#f1f1f5; --code:#f5f5f7; --link:#0067c0; --error:#b42318; }
        :root.dark { color-scheme:dark; --fg:#ececf0; --muted:#a1a1ab; --line:#3a3a40; --user:#292930; --code:#25252b; --link:#75baff; --error:#ff9d94; }
        * { box-sizing:border-box; }
        html { background:transparent; overflow-anchor:none; }
        body { margin:0; background:transparent; color:var(--fg); font:13px -apple-system,BlinkMacSystemFont,sans-serif; }
        main { max-width:900px; margin:0 auto; padding:28px 24px 36px; }
        article { margin:0 0 30px; }
        .turn-user { margin-left:clamp(20px,8vw,88px); padding:14px 17px; background:var(--user); border-radius:12px; margin-bottom:22px; }
        .turn-assistant { padding:0 1px; }
        .speaker { margin:0 0 8px; color:var(--muted); font-size:11px; font-weight:600; letter-spacing:.02em; }
        .markdown-body { font-family:-apple-system,BlinkMacSystemFont,sans-serif; font-size:14px; line-height:1.65; background:transparent!important; color:var(--fg)!important; overflow-wrap:anywhere; }
        .markdown-body > :first-child { margin-top:0!important; }
        .markdown-body > :last-child { margin-bottom:0!important; }
        .markdown-body h1 { font-size:1.6em; } .markdown-body h2 { font-size:1.35em; } .markdown-body h3 { font-size:1.15em; }
        .markdown-body h1,.markdown-body h2 { border-color:var(--line); }
        .markdown-body a { color:var(--link); }
        .markdown-body pre { position:relative; background:var(--code)!important; border:1px solid var(--line); padding:38px 14px 14px; border-radius:8px; }
        .markdown-body code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
        .markdown-body pre code { display:block; background:transparent!important; padding:0; white-space:pre; overflow-x:auto; }
        .markdown-body table { display:block; max-width:100%; overflow-x:auto; width:max-content; }
        .markdown-body table tr { background:transparent!important; border-color:var(--line); }
        .markdown-body table th,.markdown-body table td { border-color:var(--line); }
        .markdown-body blockquote { border-color:var(--line); color:var(--muted); }
        .copy-code { position:absolute; right:8px; top:7px; font:11px -apple-system,sans-serif; color:var(--muted); background:transparent; border:1px solid var(--line); border-radius:5px; padding:3px 7px; cursor:pointer; }
        .copy-code:hover { color:var(--fg); background:var(--user); } button:focus-visible,summary:focus-visible { outline:2px solid var(--link); outline-offset:3px; }
        .working { color:var(--muted); font-size:12px; margin-top:12px; }
        .working::before { content:'•'; margin-right:7px; color:var(--link); }
        .error { border-left:2px solid var(--error); padding-left:12px; margin-top:14px; color:var(--error); }
        .receipt { margin-top:17px; border-top:1px solid var(--line); padding-top:12px; }
        .receipt > summary { color:var(--muted); cursor:pointer; font-size:12px; user-select:none; }
        .receipt-content { margin:13px 0 0 15px; border-left:1px solid var(--line); padding-left:15px; }
        .operation-title { font-size:13px; font-weight:600; margin-bottom:12px; }
        .step { margin:14px 0; }
        .step-status { font-size:11px; color:var(--muted); margin-bottom:4px; }
        .step-status.failed,.step-status.blocked { color:var(--error); }
        .step-title { font-weight:600; font-size:13px; margin-bottom:4px; }
        .step-detail { font-size:12px; }
        [hidden] { display:none!important; }
        @media(max-width:540px) { main { padding:20px 16px 28px; } .turn-user { margin-left:20px; } }
        </style>
        <script nonce="\(nonce)">\(assets.lazyAsset(name: "marked.min", ext: "js"))</script>
        <script nonce="\(nonce)">\(assets.lazyAsset(name: "highlight.min", ext: "js"))</script>
        <script nonce="\(nonce)">\(assets.lazyAsset(name: "markdown-sanitizer", ext: "js"))</script>
        </head><body><main id="transcript" role="log" aria-live="off"></main>
        <script nonce="\(nonce)">
        (() => {
            'use strict';
            const root = document.getElementById('transcript');
            const nodes = new Map();
            let strings = {};
            const profile = CmuxMarkdownSanitizer.markdownProfile({
                removeElements: ['img'],
                url(ctx) {
                    if (ctx.tag !== 'a' || ctx.name !== 'href') return null;
                    try {
                        const url = new URL(ctx.value);
                        return (url.protocol === 'https:' || url.protocol === 'http:') && url.hostname ? url.href : null;
                    } catch (_) { return null; }
                },
                element(source, clean) { clean.removeAttribute('id'); return true; }
            });
            function element(tag, className, text) {
                const node = document.createElement(tag);
                if (className) node.className = className;
                if (text !== undefined) node.textContent = text;
                return node;
            }
            function markdown(node, text) {
                text = text || '';
                if (node.cmuxSource === text) return;
                node.cmuxSource = text;
                const fragment = CmuxMarkdownSanitizer.sanitizeToFragment(marked.parse(text, {gfm:true, breaks:false}), {document, profile});
                node.replaceChildren(fragment);
                node.querySelectorAll('pre > code').forEach(code => {
                    hljs.highlightElement(code);
                    const copy = element('button', 'copy-code', strings.copy);
                    copy.type = 'button';
                    copy.setAttribute('aria-label', strings.copy);
                    copy.addEventListener('click', () => {
                        window.webkit.messageHandlers.controlCenterChat.postMessage({action:'copy', text:code.textContent});
                    });
                    code.parentNode.append(copy);
                });
            }
            function makeTurn(id) {
                const article = element('article');
                article.dataset.turn = id;
                const user = element('section', 'turn-user');
                const userLabel = element('h2', 'speaker', strings.you);
                const prompt = element('div', 'markdown-body');
                user.append(userLabel, prompt);
                const assistant = element('section', 'turn-assistant');
                const assistantLabel = element('h2', 'speaker', strings.assistant);
                const response = element('div', 'markdown-body');
                const working = element('div', 'working', strings.working);
                working.setAttribute('role', 'status');
                const error = element('div', 'error markdown-body');
                error.setAttribute('role', 'alert');
                const receipt = element('details', 'receipt');
                const receiptSummary = element('summary');
                const receiptContent = element('div', 'receipt-content');
                receipt.append(receiptSummary, receiptContent);
                assistant.append(assistantLabel, response, working, error, receipt);
                article.append(user, assistant);
                root.append(article);
                return {article, prompt, response, working, error, receipt, receiptSummary, receiptContent, userLabel, assistantLabel};
            }
            function updateReceipt(turn, operation) {
                turn.receipt.hidden = !operation;
                if (!operation) return;
                const fingerprint = JSON.stringify(operation);
                if (turn.receiptFingerprint === fingerprint) return;
                turn.receiptFingerprint = fingerprint;
                turn.receiptSummary.textContent = strings.receipt + ' · ' + operation.steps.length;
                const title = element('div', 'operation-title markdown-body');
                markdown(title, operation.title);
                turn.receiptContent.replaceChildren(title);
                operation.steps.forEach(step => {
                    const section = element('section', 'step');
                    const status = element('div', 'step-status ' + step.status, strings[step.status] || step.status);
                    const title = element('div', 'step-title markdown-body');
                    const detail = element('div', 'step-detail markdown-body');
                    markdown(title, step.title);
                    markdown(detail, step.detail);
                    section.append(status, title, detail);
                    turn.receiptContent.append(section);
                });
            }
            function nearBottom() { return document.documentElement.scrollHeight - window.innerHeight - window.scrollY < 88; }
            window.cmuxChat = {
                update(payload) {
                    const follow = nearBottom();
                    const top = window.scrollY;
                    strings = payload.strings;
                    document.documentElement.classList.toggle('dark', payload.dark);
                    document.getElementById('highlight-light').media = payload.dark ? 'not all' : 'all';
                    document.getElementById('highlight-dark').media = payload.dark ? 'all' : 'not all';
                    const retained = new Set(payload.turns.map(turn => turn.id));
                    nodes.forEach((turn, id) => { if (!retained.has(id)) { turn.article.remove(); nodes.delete(id); } });
                    payload.turns.forEach(value => {
                        let turn = nodes.get(value.id);
                        if (!turn) { turn = makeTurn(value.id); nodes.set(value.id, turn); }
                        markdown(turn.prompt, value.prompt);
                        markdown(turn.response, value.response);
                        markdown(turn.error, value.error);
                        turn.error.hidden = !value.error;
                        turn.working.hidden = !value.working;
                        turn.userLabel.textContent = strings.you;
                        turn.assistantLabel.textContent = strings.assistant;
                        turn.working.textContent = strings.working;
                        updateReceipt(turn, value.operation);
                    });
                    let error = document.getElementById('standalone-error');
                    if (payload.error) {
                        if (!error) { error = element('div', 'error markdown-body'); error.id = 'standalone-error'; error.setAttribute('role','alert'); root.append(error); }
                        markdown(error, payload.error);
                    } else if (error) { error.remove(); }
                    window.scrollTo(0, follow ? document.documentElement.scrollHeight : top);
                }
            };
        })();
        </script></body></html>
        """
    }
}
