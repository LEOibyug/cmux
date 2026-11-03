import AppKit
import Combine
import Foundation

@MainActor
final class RemoteLoadingPanel: Panel {
    enum Phase {
        case loading(headline: String? = nil)
        case failed(String, elapsedSeconds: Int)
    }

    let id: UUID
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .remoteLoading
    @Published var startedAt: Date
    @Published var phase: Phase = .loading(headline: nil)

    var displayTitle: String {
        String(localized: "panel.remoteLoading.title", defaultValue: "SSH")
    }

    var displayIcon: String? { "network" }

    init(id: UUID = UUID(), workspaceId: UUID, startedAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.startedAt = startedAt
    }

    func configureLoadingHeadline(_ headline: String) {
        guard case .loading = phase else { return }
        phase = .loading(headline: headline)
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    func showFailure(_ message: String) {
        let trimmed = Self.presentableFailureMessage(from: message)
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
        phase = .failed(trimmed.isEmpty
            ? String(localized: "panel.remoteLoading.failed.generic", defaultValue: "The SSH session could not be opened.")
            : trimmed,
            elapsedSeconds: elapsedSeconds
        )
    }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    func resetLoading() {
        startedAt = Date()
        phase = .loading(headline: nil)
    }

    private static func presentableFailureMessage(from rawMessage: String) -> String {
        let cleaned = rawMessage
            .replacingOccurrences(of: "\u{001B}[2K", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let collapsed = cleaned.filter { line in
            let key = line.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return !key.contains("[cmux]")
        }
        return String(collapsed.joined(separator: "\n").prefix(600))
    }
}
