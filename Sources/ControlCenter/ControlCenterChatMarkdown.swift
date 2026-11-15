import AppKit
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
    let onRetry: (UUID) -> Void
    let onEdit: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "controlCenterChat")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.isHidden = !isVisible
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel(ControlCenterStrings.text("chatTranscriptLabel"))
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.shellHTML(dark: colorScheme == .dark), baseURL: nil)
        return webView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onRetry = onRetry
        context.coordinator.onEdit = onEdit
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
            dark: colorScheme == .dark,
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

    private static func shellHTML(dark: Bool) -> String {
        let assets = MarkdownViewerAssets.shared
        let nonce = UUID().uuidString
        return """
        <!doctype html>
        <html class="\(dark ? "dark" : "")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(assets.lazyAsset(name: "github-markdown", ext: "css"))</style>
        <style id="highlight-light" media="\(dark ? "not all" : "all")">\(assets.lazyAsset(name: "highlight-github", ext: "css"))</style>
        <style id="highlight-dark" media="\(dark ? "all" : "not all")">\(assets.lazyAsset(name: "highlight-github-dark", ext: "css"))</style>
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
        .turn-actions { display:flex; justify-content:flex-end; gap:4px; margin-top:6px; }
        .turn-actions button { display:grid; place-items:center; width:28px; height:28px; color:var(--muted); border:0; border-radius:6px; background:none; padding:6px; cursor:pointer; }
        .turn-actions button:hover:not(:disabled) { color:var(--fg); background:var(--line); }
        .turn-actions svg { width:16px; height:16px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; }
        .turn-actions button:disabled { opacity:.4; cursor:default; }
        .attachments { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
        .attachments img { width:92px; height:76px; object-fit:cover; border-radius:7px; border:1px solid var(--line); }
        .entry { margin:0 0 16px; }
        .tool-card,.reasoning-card { border:1px solid var(--line); border-radius:8px; background:var(--code); padding:10px 12px; }
        .tool-card summary,.reasoning-card summary { cursor:pointer; font-size:12px; color:var(--muted); overflow-wrap:anywhere; }
        .tool-card summary { display:flex; align-items:baseline; gap:8px; }
        .tool-name { color:var(--fg); font-weight:600; flex:1; }
        .tool-status { font-size:11px; }
        .tool-status.failed,.tool-status.blocked { color:var(--error); }
        .tool-arguments { margin-top:10px; color:var(--muted); font-size:11px; }
        .tool-card pre { white-space:pre-wrap; overflow-wrap:anywhere; font:11px ui-monospace,SFMono-Regular,Menlo,monospace; margin:6px 0 0; max-height:220px; overflow:auto; }
        .tool-result,.reasoning-text { margin-top:10px; font-size:12px; }
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
                const user = element('section', 'turn-user');
                const userLabel = element('h2', 'speaker', strings.you);
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
                user.append(userLabel, prompt, attachments, actions);
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
                article.append(user, assistant);
                root.append(article);
                return {article, prompt, attachments, edit, retry, timeline, entries:new Map(), response, working, error, receipt, receiptSummary, receiptContent, userLabel, assistantLabel};
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
                        turn.userLabel.textContent = strings.you;
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
