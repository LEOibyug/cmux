import AppKit
import CmuxAppKitSupportUI
import CmuxControlCenter
import SwiftUI
import WebKit

struct ControlCenterChatMarkdown: NSViewRepresentable {
    let turns: [ControlCenterChatTurn]
    let activeTurnID: UUID?
    let liveResponse: String
    let liveEntries: [ControlCenterChatEntry]
    let liveOperation: ControlCenterOperation?
    let liveError: String?
    let isRunning: Bool
    let standaloneError: String?
    let isAwaitingApproval: Bool
    let isVisible: Bool
    var themeBackgroundHex: String = "#1e1e24"
    var themeForegroundHex: String = "#ececf0"
    var themeBorderHex: String = "#34343a"
    var accentHex: String = "#6cb6ff"
    var themeColorScheme: ColorScheme?
    let onRetry: (UUID) -> Void
    let onEdit: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveColorScheme: ColorScheme {
        themeColorScheme ?? colorScheme
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "controlCenterChat")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        let scheme = effectiveColorScheme
        webView.appearance = WindowAppearanceSnapshot.appKitAppearance(for: scheme)
        webView.isHidden = !isVisible
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel(ControlCenterStrings.text("chatTranscriptLabel"))
        context.coordinator.webView = webView
        webView.loadHTMLString(
            Self.shellHTML(
                dark: scheme == .dark,
                themeBackground: themeBackgroundHex,
                themeForeground: themeForegroundHex,
                themeBorder: themeBorderHex,
                accent: accentHex
            ),
            baseURL: nil
        )
        return webView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onRetry = onRetry
        context.coordinator.onEdit = onEdit
        let scheme = effectiveColorScheme
        let appearance = WindowAppearanceSnapshot.appKitAppearance(for: scheme)
        if webView.appearance?.name != appearance.name {
            webView.appearance = appearance
        }
        webView.isHidden = !isVisible
        if !isVisible, let window = webView.window,
           let responder = window.firstResponder as? NSView,
           responder === webView || responder.isDescendant(of: webView) {
            window.makeFirstResponder(nil)
        }
        let payload = TranscriptPayload(
            turns: turns.map { turn in
                let active = turn.id == activeTurnID
                return TurnPayload(
                    id: turn.id.uuidString,
                    prompt: turn.prompt,
                    response: active ? liveResponse : turn.response,
                    attachments: turn.attachments.map { AttachmentPayload(id: $0.id.uuidString, name: $0.name) },
                    entries: (active ? liveEntries : turn.entries).map {
                        EntryPayload(id: $0.id, kind: $0.kind, title: $0.title, text: $0.text, status: $0.status, arguments: $0.arguments)
                    },
                    operation: active ? liveOperation : turn.operation,
                    error: active ? liveError : turn.error,
                    working: active && isRunning
                )
            },
            error: standaloneError,
            dark: scheme == .dark,
            themeBackground: themeBackgroundHex,
            themeForeground: themeForegroundHex,
            themeBorder: themeBorderHex,
            accent: accentHex,
            actionsEnabled: !isRunning && isVisible,
            strings: [
                "you": ControlCenterStrings.text("chatYou"),
                "assistant": ControlCenterStrings.text("chatAssistant"),
                "working": ControlCenterStrings.text(isAwaitingApproval ? "chatApprovalNeeded" : "chatWorking"),
                "receipt": ControlCenterStrings.text("chatReceipt"),
                "copy": ControlCenterStrings.text("chatCopyCode"),
                "edit": ControlCenterStrings.text("chatEditMessage"),
                "retry": ControlCenterStrings.text("chatRetryMessage"),
                "reasoning": ControlCenterStrings.text("chatReasoningSummary"),
                "arguments": ControlCenterStrings.text("chatToolArguments"),
                "preparing": ControlCenterStrings.text("chatToolPreparing"),
                "running": ControlCenterStrings.text("chatToolRunning"),
                "waiting": ControlCenterStrings.text("chatToolWaiting"),
                "success": ControlCenterStrings.text("success"),
                "failed": ControlCenterStrings.text("failed"),
                "blocked": ControlCenterStrings.text("blocked"),
                "cancelled": ControlCenterStrings.text("cancelled")
            ]
        )
        context.coordinator.update(payload, attachments: turns.flatMap(\.attachments))
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
        let attachments: [AttachmentPayload]
        let entries: [EntryPayload]
        let operation: ControlCenterOperation?
        let error: String?
        let working: Bool
    }

    fileprivate struct AttachmentPayload: Encodable, Equatable {
        let id: String
        let name: String
    }

    fileprivate struct EntryPayload: Encodable, Equatable {
        let id: String
        let kind: String
        let title: String
        let text: String
        let status: String
        let arguments: String
    }

    fileprivate struct TranscriptPayload: Encodable, Equatable {
        let turns: [TurnPayload]
        let error: String?
        let dark: Bool
        let themeBackground: String
        let themeForeground: String
        let themeBorder: String
        let accent: String
        let actionsEnabled: Bool
        let strings: [String: String]
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onRetry: ((UUID) -> Void)?
        var onEdit: ((UUID) -> Void)?
        private var cachedImageIDs = Set<String>()
        private var pendingImages: [String: String] = [:]
        private var isReady = false
        private var isScheduled = false
        private var latest: TranscriptPayload?
        private var pending: TranscriptPayload?
        private var failureLabel: NSTextField?

        fileprivate func update(_ payload: TranscriptPayload, attachments: [ControlCenterChatAttachment]) {
            let retainedIDs = Set(attachments.map { $0.id.uuidString })
            cachedImageIDs.formIntersection(retainedIDs)
            pendingImages = pendingImages.filter { retainedIDs.contains($0.key) }
            for attachment in attachments where !cachedImageIDs.contains(attachment.id.uuidString) {
                pendingImages[attachment.id.uuidString] = attachment.dataURL
            }
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
                    let imageData = try JSONEncoder().encode(self.pendingImages)
                    let images = String(decoding: imageData, as: UTF8.self)
                    self.cachedImageIDs.formUnion(self.pendingImages.keys)
                    self.pendingImages.removeAll()
                    webView.evaluateJavaScript("window.cmuxChat.update(\(json), \(images));") { [weak self] _, error in
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
                  let action = body["action"] else { return }
            if action == "copy", let code = body["text"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                return
            }
            guard latest?.actionsEnabled == true,
                  let value = body["turnID"], let id = UUID(uuidString: value),
                  latest?.turns.contains(where: { $0.id == id.uuidString }) == true else { return }
            if action == "retry" { onRetry?(id) }
            if action == "edit" { onEdit?(id) }
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

    private static func safeHex(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.first == "#" else { return fallback }
        guard trimmed.dropFirst().allSatisfy({ $0.isHexDigit }) else { return fallback }
        return trimmed
    }

    private static func shellHTML(
        dark: Bool,
        themeBackground: String,
        themeForeground: String,
        themeBorder: String,
        accent: String
    ) -> String {
        let assets = MarkdownViewerAssets.shared
        let nonce = UUID().uuidString
        let bg = safeHex(themeBackground, fallback: dark ? "#1e1e24" : "#f6f7f9")
        let fg = safeHex(themeForeground, fallback: dark ? "#ececf0" : "#1d1d1f")
        let border = safeHex(themeBorder, fallback: dark ? "#34343a" : "#d8d8de")
        let accentColor = safeHex(accent, fallback: dark ? "#6cb6ff" : "#0066cc")
        let initialStyle = "--theme-bg:\(bg);--fg:\(fg);--line:\(border);--accent:\(accentColor)"
        return """
        <!doctype html>
        <html class="\(dark ? "dark" : "")" style="\(initialStyle)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(assets.lazyAsset(name: "github-markdown", ext: "css"))</style>
        <style id="highlight-light" media="\(dark ? "not all" : "all")">\(assets.lazyAsset(name: "highlight-github", ext: "css"))</style>
        <style id="highlight-dark" media="\(dark ? "all" : "not all")">\(assets.lazyAsset(name: "highlight-github-dark", ext: "css"))</style>
        <style>
        :root {
            color-scheme: light;
            --theme-bg:#f6f7f9; --accent:#0066cc;
            --fg:#1d1d1f; --muted:color-mix(in srgb, var(--fg) 56%, var(--theme-bg));
            --line:color-mix(in srgb, var(--fg) 12%, var(--theme-bg));
            --user:color-mix(in srgb, var(--accent) 8%, color-mix(in srgb, var(--fg) 4%, var(--theme-bg)));
            --user-border:color-mix(in srgb, var(--accent) 22%, var(--line));
            --code:color-mix(in srgb, var(--fg) 4.5%, var(--theme-bg));
            --link:var(--accent); --error:#b42318; --ok:#157f3b; --warn:#b25000;
            --badge-bg:color-mix(in srgb, var(--fg) 6%, transparent); --badge-active:color-mix(in srgb, var(--accent) 14%, transparent);
            --badge-ok:rgba(21,127,59,.11); --badge-warn:rgba(178,80,0,.11); --badge-err:rgba(180,35,24,.10);
        }
        :root.dark {
            color-scheme: dark;
            --theme-bg:#1e1e24; --accent:#6cb6ff;
            --fg:#ececf0; --muted:color-mix(in srgb, var(--fg) 62%, var(--theme-bg));
            --line:color-mix(in srgb, var(--fg) 12%, var(--theme-bg));
            --user:color-mix(in srgb, var(--accent) 12%, color-mix(in srgb, var(--fg) 6%, var(--theme-bg)));
            --user-border:color-mix(in srgb, var(--accent) 28%, var(--line));
            --code:color-mix(in srgb, var(--fg) 5%, var(--theme-bg));
            --link:var(--accent); --error:#ff948a; --ok:#56d364; --warn:#f0a020;
            --badge-bg:color-mix(in srgb, var(--fg) 8%, transparent); --badge-active:color-mix(in srgb, var(--accent) 18%, transparent);
            --badge-ok:rgba(86,211,100,.14); --badge-warn:rgba(240,160,32,.15); --badge-err:rgba(255,148,138,.14);
        }
        * { box-sizing:border-box; }
        html { background:transparent; overflow-anchor:none; }
        body { margin:0; background:transparent; color:var(--fg); font:13px -apple-system,BlinkMacSystemFont,sans-serif; -webkit-font-smoothing:antialiased; }
        main { max-width:900px; margin:0 auto; padding:22px 24px 32px; }
        article { margin:0 0 22px; padding-bottom:18px; border-bottom:1px solid color-mix(in srgb, var(--line) 55%, transparent); }
        article:last-of-type { border-bottom:0; margin-bottom:8px; padding-bottom:4px; }
        .user-message { position:relative; display:flex; flex-direction:column; align-items:flex-end; gap:3px; margin:0 0 8px clamp(24px,9vw,96px); }
        .turn-user { width:fit-content; max-width:100%; min-width:0; padding:9px 14px; background:var(--user); border:1px solid var(--user-border); border-radius:14px 14px 4px 14px; }
        .turn-assistant { padding:0 2px; }
        .speaker { display:flex; align-items:center; gap:6px; margin:0 0 8px; color:var(--muted); font-size:11px; font-weight:600; letter-spacing:.02em; }
        .speaker::before { content:''; width:6px; height:6px; border-radius:50%; background:var(--link); opacity:.85; }
        .turn-actions { display:flex; gap:3px; min-height:24px; opacity:0; pointer-events:none; transition:opacity .12s ease; }
        .user-message:hover .turn-actions,.user-message:focus-within .turn-actions { opacity:1; pointer-events:auto; }
        @media (prefers-reduced-motion:reduce) { .turn-actions { transition:none; } }
        .turn-actions button { display:grid; place-items:center; width:24px; height:24px; color:var(--muted); border:0; border-radius:6px; background:none; padding:4px; cursor:pointer; }
        .turn-actions button:hover:not(:disabled) { color:var(--fg); background:var(--badge-bg); }
        .turn-actions svg { width:14px; height:14px; fill:none; stroke:currentColor; stroke-width:1.75; stroke-linecap:round; stroke-linejoin:round; }
        .turn-actions button:disabled { opacity:.4; cursor:default; }
        .attachments { display:flex; gap:8px; flex-wrap:wrap; margin-top:8px; }
        .attachments:empty { display:none; }
        .turn-user .markdown-body:empty + .attachments { margin-top:0; }
        .attachments img { width:92px; height:72px; object-fit:cover; border-radius:7px; border:1px solid var(--line); }
        .entry { margin:0 0 10px; }
        .tool-card,.reasoning-card { border:1px solid var(--line); border-radius:9px; background:var(--code); padding:8px 12px; }
        .tool-card summary,.reasoning-card summary { cursor:pointer; font-size:12px; color:var(--muted); overflow-wrap:anywhere; user-select:none; }
        .tool-card summary { display:flex; align-items:center; gap:8px; }
        .tool-name { color:var(--fg); font-weight:600; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11.5px; flex:1; }
        .tool-status { font-size:10.5px; font-weight:600; padding:2px 7px; border-radius:999px; background:var(--badge-bg); color:var(--muted); white-space:nowrap; }
        .tool-status.preparing,.tool-status.running { color:var(--link); background:var(--badge-active); }
        .tool-status.waiting { color:var(--warn); background:var(--badge-warn); }
        .tool-status.success { color:var(--ok); background:var(--badge-ok); }
        .tool-status.failed,.tool-status.blocked { color:var(--error); background:var(--badge-err); }
        .tool-arguments { margin-top:8px; color:var(--muted); font-size:11px; font-weight:500; }
        .tool-card pre { white-space:pre-wrap; overflow-wrap:anywhere; font:11px ui-monospace,SFMono-Regular,Menlo,monospace; margin:5px 0 0; padding:7px 9px; border-radius:6px; background:var(--badge-bg); max-height:200px; overflow:auto; }
        .tool-result,.reasoning-text { margin-top:8px; font-size:12.5px; padding-top:8px; border-top:1px solid var(--line); }
        .tool-result:empty,.reasoning-text:empty { display:none; }
        .markdown-body { font-family:-apple-system,BlinkMacSystemFont,sans-serif; font-size:13.5px; line-height:1.62; background:transparent!important; color:var(--fg)!important; overflow-wrap:anywhere; }
        .markdown-body > :first-child { margin-top:0!important; }
        .markdown-body > :last-child { margin-bottom:0!important; }
        .markdown-body h1 { font-size:1.5em; } .markdown-body h2 { font-size:1.3em; } .markdown-body h3 { font-size:1.12em; }
        .markdown-body h1,.markdown-body h2 { border-color:var(--line); }
        .markdown-body a { color:var(--link); text-decoration:none; }
        .markdown-body a:hover { text-decoration:underline; }
        .markdown-body pre { position:relative; background:var(--code)!important; border:1px solid var(--line); padding:12px 70px 12px 14px; border-radius:9px; }
        .markdown-body code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
        .markdown-body pre code { display:block; background:transparent!important; padding:0; white-space:pre; overflow-x:auto; }
        .markdown-body table { display:block; max-width:100%; overflow-x:auto; width:max-content; }
        .markdown-body table tr { background:transparent!important; border-color:var(--line); }
        .markdown-body table th,.markdown-body table td { border-color:var(--line); }
        .markdown-body blockquote { border-color:var(--line); color:var(--muted); }
        .copy-code { position:absolute; right:8px; top:8px; font:11px -apple-system,sans-serif; color:var(--muted); background:var(--code); border:1px solid var(--line); border-radius:6px; padding:3px 8px; cursor:pointer; transition:color .12s ease,border-color .12s ease; }
        .copy-code:hover { color:var(--fg); background:var(--user); }
        .copy-code.copied { color:var(--ok); border-color:var(--ok); }
        button:focus-visible,summary:focus-visible { outline:2px solid var(--link); outline-offset:2px; }
        @keyframes cc-pulse { 0%,100% { opacity:1; } 50% { opacity:.32; } }
        .working { display:inline-flex; align-items:center; gap:7px; color:var(--muted); font-size:12px; margin-top:10px; padding:4px 10px; border-radius:999px; background:var(--badge-bg); }
        .working::before { content:''; width:7px; height:7px; border-radius:50%; background:var(--link); animation:cc-pulse 1.4s ease-in-out infinite; }
        @media (prefers-reduced-motion:reduce) { .working::before { animation:none; } }
        .error { border:1px solid color-mix(in srgb, var(--error) 35%, transparent); border-left:3px solid var(--error); border-radius:7px; background:var(--badge-err); padding:9px 12px; margin-top:12px; color:var(--error); }
        .receipt { margin-top:14px; border:1px solid var(--line); border-radius:9px; background:var(--code); padding:8px 12px; }
        .receipt > summary { color:var(--muted); cursor:pointer; font-size:12px; font-weight:500; user-select:none; }
        .receipt-content { margin:10px 0 0; border-top:1px solid var(--line); padding-top:10px; }
        .operation-title { font-size:12.5px; font-weight:600; margin-bottom:8px; }
        .step { margin:10px 0; padding-left:10px; border-left:2px solid var(--line); }
        .step-status { display:inline-block; font-size:10.5px; font-weight:600; padding:1px 6px; border-radius:999px; background:var(--badge-bg); color:var(--muted); margin-bottom:3px; }
        .step-status.success { color:var(--ok); background:var(--badge-ok); }
        .step-status.failed,.step-status.blocked { color:var(--error); background:var(--badge-err); }
        .step-title { font-weight:600; font-size:12.5px; margin-bottom:2px; }
        .step-detail { font-size:12px; color:var(--muted); }
        [hidden] { display:none!important; }
        @media(max-width:540px) { main { padding:16px 14px 24px; } .user-message { margin-left:16px; } }
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
            const imageCache = new Map();
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
                        copy.textContent = '✓ ' + strings.copy;
                        copy.classList.add('copied');
                        clearTimeout(copy.cmuxTimer);
                        copy.cmuxTimer = setTimeout(() => {
                            copy.textContent = strings.copy;
                            copy.classList.remove('copied');
                        }, 1200);
                    });
                    code.parentNode.append(copy);
                });
            }
            function actionButton(path) {
                const button = element('button');
                button.type = 'button';
                button.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${path}"></path></svg>`;
                return button;
            }
            function makeTurn(id) {
                const article = element('article');
                article.dataset.turn = id;
                const userMessage = element('div', 'user-message');
                const user = element('section', 'turn-user');
                user.setAttribute('aria-label', strings.you);
                const prompt = element('div', 'markdown-body');
                const attachments = element('div', 'attachments');
                const actions = element('div', 'turn-actions');
                const edit = actionButton('M17 3a2.83 2.83 0 0 1 4 4L7 21l-5 1 1-5ZM15 5l4 4');
                const retry = actionButton('M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8M21 3v5h-5');
                edit.addEventListener('click', () => {
                    if (!edit.disabled) window.webkit.messageHandlers.controlCenterChat.postMessage({action:'edit', turnID:id});
                });
                retry.addEventListener('click', () => {
                    if (!retry.disabled) window.webkit.messageHandlers.controlCenterChat.postMessage({action:'retry', turnID:id});
                });
                actions.append(edit, retry);
                user.append(prompt, attachments);
                userMessage.append(user, actions);
                const assistant = element('section', 'turn-assistant');
                const assistantLabel = element('h2', 'speaker', strings.assistant);
                const response = element('div', 'markdown-body');
                const timeline = element('div', 'timeline');
                const working = element('div', 'working', strings.working);
                working.setAttribute('role', 'status');
                const error = element('div', 'error markdown-body');
                error.setAttribute('role', 'alert');
                const receipt = element('details', 'receipt');
                const receiptSummary = element('summary');
                const receiptContent = element('div', 'receipt-content');
                receipt.append(receiptSummary, receiptContent);
                assistant.append(assistantLabel, timeline, response, working, error, receipt);
                article.append(userMessage, assistant);
                root.append(article);
                return {article, user, prompt, attachments, edit, retry, timeline, entries:new Map(), response, working, error, receipt, receiptSummary, receiptContent, assistantLabel};
            }
            function makeEntry(value) {
                if (value.kind === 'text') {
                    const node = element('div', 'entry markdown-body');
                    return {node, content:node, kind:value.kind};
                }
                const tool = value.kind === 'tool';
                const node = element('details', tool ? 'entry tool-card' : 'entry reasoning-card');
                const summary = element('summary');
                const title = element('span', tool ? 'tool-name' : '', tool ? value.title : strings.reasoning);
                const status = element('span', 'tool-status');
                summary.append(title);
                if (tool) summary.append(status);
                const content = element('div', tool ? 'tool-result markdown-body' : 'reasoning-text markdown-body');
                const argumentsLabel = element('div', 'tool-arguments', strings.arguments);
                const argumentsText = element('pre');
                node.append(summary);
                if (tool) node.append(argumentsLabel, argumentsText);
                node.append(content);
                return {node, title, status, content, argumentsLabel, argumentsText, kind:value.kind};
            }
            function updateEntries(turn, values) {
                const retained = new Set(values.map(value => value.id));
                turn.entries.forEach((entry, id) => {
                    if (!retained.has(id)) { entry.node.remove(); turn.entries.delete(id); }
                });
                values.forEach((value, index) => {
                    let entry = turn.entries.get(value.id);
                    if (entry && entry.kind !== value.kind) { entry.node.remove(); turn.entries.delete(value.id); entry = null; }
                    if (!entry) { entry = makeEntry(value); turn.entries.set(value.id, entry); }
                    if (turn.timeline.children[index] !== entry.node) {
                        turn.timeline.insertBefore(entry.node, turn.timeline.children[index] || null);
                    }
                    markdown(entry.content, value.text);
                    if (value.kind !== 'text') entry.title.textContent = value.kind === 'tool' ? value.title : strings.reasoning;
                    if (value.kind === 'tool') {
                        const status = ['preparing','running','waiting','success','failed','blocked','cancelled'].includes(value.status) ? value.status : 'preparing';
                        entry.status.textContent = strings[status] || status;
                        entry.status.className = 'tool-status ' + status;
                        entry.argumentsLabel.textContent = strings.arguments;
                        entry.argumentsLabel.hidden = !value.arguments;
                        entry.argumentsText.hidden = !value.arguments;
                        if (entry.argumentsText.textContent !== value.arguments) entry.argumentsText.textContent = value.arguments;
                        entry.content.hidden = !value.text;
                    }
                });
            }
            function updateAttachments(turn, values) {
                const fingerprint = values.map(value => value.id).join(',');
                if (turn.attachmentFingerprint === fingerprint) return;
                turn.attachmentFingerprint = fingerprint;
                turn.attachments.replaceChildren();
                values.forEach(value => {
                    const data = imageCache.get(value.id);
                    if (!data || !/^data:image\\/(png|jpeg|gif|webp|heic|heif);base64,/i.test(data)) return;
                    const image = element('img');
                    image.src = data;
                    image.alt = value.name;
                    image.title = value.name;
                    image.width = 92;
                    image.height = 76;
                    turn.attachments.append(image);
                });
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
                update(payload, images) {
                    const follow = nearBottom();
                    const top = window.scrollY;
                    strings = payload.strings;
                    Object.entries(images || {}).forEach(([id, data]) => imageCache.set(id, data));
                    const retainedImages = new Set(payload.turns.flatMap(turn => turn.attachments.map(image => image.id)));
                    imageCache.forEach((_, id) => { if (!retainedImages.has(id)) imageCache.delete(id); });
                    document.documentElement.classList.toggle('dark', payload.dark);
                    if (/^#[0-9a-fA-F]{6}$/.test(payload.themeBackground || '')) {
                        document.documentElement.style.setProperty('--theme-bg', payload.themeBackground);
                    }
                    if (/^#[0-9a-fA-F]{6}$/.test(payload.themeForeground || '')) {
                        document.documentElement.style.setProperty('--fg', payload.themeForeground);
                    }
                    if (/^#[0-9a-fA-F]{6}$/.test(payload.themeBorder || '')) {
                        document.documentElement.style.setProperty('--line', payload.themeBorder);
                    }
                    if (/^#[0-9a-fA-F]{6}$/.test(payload.accent || '')) {
                        document.documentElement.style.setProperty('--accent', payload.accent);
                    }
                    document.getElementById('highlight-light').media = payload.dark ? 'not all' : 'all';
                    document.getElementById('highlight-dark').media = payload.dark ? 'all' : 'not all';
                    const retained = new Set(payload.turns.map(turn => turn.id));
                    nodes.forEach((turn, id) => { if (!retained.has(id)) { turn.article.remove(); nodes.delete(id); } });
                    payload.turns.forEach(value => {
                        let turn = nodes.get(value.id);
                        if (!turn) { turn = makeTurn(value.id); nodes.set(value.id, turn); }
                        markdown(turn.prompt, value.prompt);
                        if (value.entries.length === 0) markdown(turn.response, value.response);
                        turn.response.hidden = value.entries.length > 0;
                        updateEntries(turn, value.entries);
                        updateAttachments(turn, value.attachments);
                        turn.edit.title = strings.edit;
                        turn.edit.setAttribute('aria-label', strings.edit);
                        turn.retry.title = strings.retry;
                        turn.retry.setAttribute('aria-label', strings.retry);
                        turn.edit.disabled = !payload.actionsEnabled;
                        turn.retry.disabled = !payload.actionsEnabled;
                        markdown(turn.error, value.error);
                        turn.error.hidden = !value.error;
                        turn.working.hidden = !value.working;
                        turn.user.setAttribute('aria-label', strings.you);
                        turn.assistantLabel.textContent = strings.assistant;
                        turn.working.textContent = strings.working;
                        updateReceipt(turn, value.entries.length === 0 ? value.operation : null);
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
