import AppKit
import SwiftUI

/// Keeps SSH browser connection controls alive while portal content is retained.
struct RemoteBrowserAccessView<Content: View>: View {
    let panel: BrowserPanel
    let backgroundColor: NSColor
    let isVisibleInUI: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let state = panel.remoteAccess
        Group {
            if let model = state.model {
                if state.showsPage || state.failureMessage == nil {
                    content()
                } else {
                    connectionCard(message: state.failureMessage ?? model.failureMessage, retry: { _ = panel.reload() })
                }
            } else if state.isRestoring {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(String(localized: "remote.browser.restoring", defaultValue: "Reconnecting to remote host…"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = state.starting {
                ProgressView(message)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = state.unavailable {
                connectionCard(message: message, retry: state.unavailableRetryAction)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: backgroundColor))
        .accessibilityIdentifier("RemoteBrowserAccess")
        .overlay {
            if isVisibleInUI && state.showsFailureAlert {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "remote.browser.unavailable", defaultValue: "Remote session unavailable"))
                        .font(.headline)
                    Text(state.failureMessage ?? "")
                        .textSelection(.enabled)
                    HStack {
                        Button(String(localized: "common.copy", defaultValue: "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.failureMessage ?? "", forType: .string)
                        }
                        if state.model != nil {
                            Button(String(localized: "common.retry", defaultValue: "Retry")) { _ = panel.reload() }
                        }
                        Button(String(localized: "common.dismiss", defaultValue: "Dismiss")) { state.dismissFailure() }
                    }
                }
                .padding(16)
                .frame(maxWidth: 320)
                .background(Color(nsColor: backgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .ghosttyDialogTheme()
                .padding(12)
            }
        }
        .onChange(of: showsNativeContent, initial: true) { _, shown in
            if shown { BrowserWindowPortalRegistry.hide(webView: panel.webView, source: "remoteConnection") }
        }
    }

    private func connectionCard(message: String?, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            if let message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                ProgressView()
            }
            if let address = panel.remoteAccess.remoteURL?.absoluteString, !address.isEmpty {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let retry {
                Button(String(localized: "common.retry", defaultValue: "Retry"), action: retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ghosttyDialogTheme()
    }

    private var showsNativeContent: Bool {
        let state = panel.remoteAccess
        return state.unavailable != nil || state.isRestoring || state.starting != nil
            || state.failureMessage != nil
    }
}
