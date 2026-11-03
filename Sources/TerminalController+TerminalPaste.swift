import Foundation

extension TerminalController {
    /// Pastes literal text and optionally submits it using the terminal agent’s key policy.
    func v2TerminalPaste(params: [String: Any]) async -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        // Resolve the optional submit key up front so an unsupported value fails
        // before any text is pasted (no partial application). The caller sends
        // `return` as the default submit *intent*; the agent-aware upgrade to
        // `ctrl+enter` happens below once the surface (and its agent context) is
        // resolved, because only the Mac knows which agent is running.
        let submitKeyRaw = (v2String(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(code: "invalid_params", message: "Unsupported submit_key", data: ["submit_key": submitKeyRaw])
        }
        guard let resolved = canonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let surfaceId = resolved.surfaceID
        let terminalTarget = resolved.target
        let terminalPanel = terminalTarget.panel
        guard terminalPasteInFlightSurfaceIDs.insert(surfaceId).inserted else {
            return .err(code: "busy", message: "A prompt is already being submitted to this terminal", data: nil)
        }
        defer { terminalPasteInFlightSurfaceIDs.remove(surfaceId) }

        // Mirror the macOS TextBox composer's submit-key selection
        // (`TextBoxInput.dispatchEvents`): Claude Code needs `ctrl+enter` to
        // submit a multi-line block, while plain `return` submits a newline mid
        // prompt. The caller need not know the running agent, so it always asks for
        // `return`; upgrade that intent here when the surface is Claude and the
        // composed text spans multiple lines. Explicit `ctrl+enter`/`none` from
        // the client are honored as-is.
        if submitKeyWasReturnIntent {
            submitKeyName = TextBoxAgentDetection.composedPromptSubmitKey(
                containsNewline: text.contains("\n") || text.contains("\r"),
                context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
            )
        }


        // Send through the TerminalPanel explicit-input wrappers (not the raw
        // surface): they run `resumeForExplicitInputIfNeeded()` first, waking a
        // hibernated agent terminal the same way local typing does, so a local
        // composer submit cannot write into a cold surface.
        let textResult = terminalTarget.sendTextResult(text)
        // The paste and its submit key are one unit: once the text is
        // accepted the unit counts as applied, even if the submit key fails
        // (reported below), so a resend never pastes the block twice.
        switch textResult {
        case .sent, .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }

        // The paste text is already accepted by the surface above. From here on a
        // submit-key failure must NOT surface as an RPC error: the client treats
        // any error as "nothing was sent" and keeps the composer draft, so a
        // retry would paste the whole block a second time. Report partial
        // success instead — `submitted: false` plus `submit_error` — so the
        // client clears the draft (the text is sitting at the prompt) and can
        // tell the user the submit keypress is still needed.
        var submitted = false
        var submitError: String?
        if let submitKeyName {
            // Gemini's editor treats Enter during its 40 ms paste-protection
            // window as a newline. React-based editors can also process paste
            // and Enter in one render with a stale, empty input buffer. Keep a
            // separate input turn, with margin for the documented cooldown,
            // and await it before acknowledging submission to the caller.
            let generation = terminalTarget.surface.runtimeSurfaceGeneration
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return .ok([
                    "workspace_id": resolved.workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "submitted": false,
                    "submit_error": "cancelled",
                ])
            }
            // Closing/replacing a terminal during the suspension must never
            // send Enter into a different process or a newly created surface.
            guard let current = canonicalTerminalTarget(params: params)?.target,
                  current.surface === terminalTarget.surface,
                  current.surface.runtimeSurfaceGeneration == generation else {
                return .ok([
                    "workspace_id": resolved.workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "submitted": false,
                    "submit_error": "surface_changed",
                ])
            }
            let keyResult = current.sendNamedKeyResult(submitKeyName)
            if keyResult.accepted {
                submitted = true
            } else {
                switch keyResult {
                case .inputQueueFull:
                    submitError = "input_queue_full"
                case .surfaceUnavailable:
                    submitError = "surface_unavailable"
                case .processExited:
                    submitError = "process_exited"
                case .unknownKey, .sent, .queued:
                    // .sent / .queued are accepted results and unreachable in this
                    // else-branch; grouped here only to keep the switch exhaustive.
                    submitError = "unknown_key"
                }
            }
        }

        terminalTarget.forceRefresh(reason: "terminal.paste")

        if submitted,
           let rawEventID = v2String(params, "feed_event_id"),
           let eventID = UUID(uuidString: rawEventID) {
            _ = FeedCoordinator.shared.store?.recordTerminalReply(eventID, text: text)
        }

        #if DEBUG
        cmuxDebugLog(
            "terminal.paste workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) chars=\(text.count) submitted=\(submitted ? 1 : 0)"
        )
        #endif

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "delivery": textResult == .sent ? "delivered" : "queued",
            "submitted": submitted,
        ]
        if let submitError {
            payload["submit_error"] = submitError
        }
        return .ok(payload)
    }

}
