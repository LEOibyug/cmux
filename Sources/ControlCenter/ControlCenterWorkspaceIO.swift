import CmuxControlCenter
import CmuxCore
import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation

private struct ControlCenterOMPInputEndpoint: Decodable, Equatable {
    let version: Int
    let workspace_id: String
    let panel_id: String
    let session_id: String
    let pid: Int32
    let instance_id: String
    let port: Int
    let token: String
}

private final class ControlCenterOMPNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private struct ControlCenterWorkspaceIOTarget {
    let workspace: Workspace
    let panel: TerminalPanel
}

private struct ControlCenterWorkspaceOutputRange {
    let lines: Int
    let offsetLines: Int
    let maxBytes: Int

    init(_ arguments: [String: ControlCenterJSON]) throws {
        lines = try Self.integer(arguments, key: "lines", default: 120, range: 1...1000)
        offsetLines = try Self.integer(arguments, key: "offset_lines", default: 0, range: 0...10000)
        maxBytes = try Self.integer(arguments, key: "max_bytes", default: 262_144, range: 1...1_048_576)
        guard offsetLines + lines <= 10000 else {
            throw ControlCenterHostError.blocked("offset_lines + lines must not exceed 10000.")
        }
    }

    var fields: [String: ControlCenterJSON] {
        ["lines": .number(Double(lines)), "offset_lines": .number(Double(offsetLines)), "max_bytes": .number(Double(maxBytes))]
    }

    static func integer(_ arguments: [String: ControlCenterJSON], key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = arguments[key] else { return fallback }
        guard let number = value.numberValue, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw ControlCenterHostError.blocked("\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return Int(number)
    }
}

extension ControlCenterCoordinator {
    func workspaceIOState(for workspace: Workspace) -> ControlCenterJSON {
        let panels = workspace.panels.values.compactMap { $0 as? TerminalPanel }.sorted { $0.id.uuidString < $1.id.uuidString }
        return .object([
            "terminal_panels": .array(panels.prefix(100).map { panel in
                let endpoint = try? workspaceOMPInputEndpoint(workspace: workspace, panel: panel)
                return .object([
                    "panel_id": .string(panel.id.uuidString),
                    "title": .string(String(panel.title.prefix(256))),
                    "output_origin": .string("terminal"),
                    "runtime_available": .bool(workspaceTerminalIsBound(workspace: workspace, panel: panel)),
                    "agent_kind": endpoint == nil ? .null : .string("omp"),
                    "session_id": endpoint.map { .string($0.session_id) } ?? .null,
                    "agent_status": .string(endpoint == nil ? "unverified" : "process_alive"),
                    "omp_input_channel": .string(endpoint == nil ? "unavailable" : "registered"),
                    "message_delivery": .string("native_sdk_only_no_pty_fallback")
                ])
            }),
            "panel_id_required": .bool(panels.count > 1),
            "panels_truncated": .bool(panels.count > 100)
        ])
    }

    func readWorkspaceOutput(_ call: ControlCenterToolCall) async throws -> ControlCenterJSON {
        let args = try workspaceIOArguments(call, sending: false)
        let range = try ControlCenterWorkspaceOutputRange(args)
        guard let format = (args["format"] ?? .string("text")).stringValue, ["text", "vt"].contains(format) else {
            throw ControlCenterHostError.blocked("format must be text or vt.")
        }
        let target = try workspaceIOTarget(args)
        let approvedRuntime = target.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.readWorkspaceOutput")
        if let request = args["request_id"] {
            guard let raw = request.stringValue, let id = UUID(uuidString: raw), format == "text" else {
                throw ControlCenterHostError.blocked("request_id must be an exact delivery UUID; request results support text format only.")
            }
            let endpoint = try workspaceOMPInputEndpoint(workspace: target.workspace, panel: target.panel)
            try await authorizeTool(call, plannedDetail: "Read OMP request \(id); workspace \(target.workspace.id), panel \(target.panel.id); skip newest \(range.offsetLines) lines, return at most \(range.lines) lines and \(range.maxBytes) UTF-8 bytes.")
            let current = try workspaceIOTarget(args)
            guard current.workspace === target.workspace, current.panel === target.panel,
                  current.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.readWorkspaceOutput.revalidate") == approvedRuntime,
                  try workspaceOMPInputEndpoint(workspace: current.workspace, panel: current.panel) == endpoint else {
                throw ControlCenterHostError.blocked("The exact OMP request target changed. Nothing was sent.")
            }
            var fields = range.fields
            fields["delivery_request_id"] = .string(id.uuidString.lowercased())
            let result = try await workspaceOMPRequest(endpoint, action: "result", fields: fields)
            return workspaceOMPResult(result, workspace: current.workspace, panel: current.panel)
        }
        try await authorizeTool(call, plannedDetail: "Read terminal output; workspace \(target.workspace.id), panel \(target.panel.id); skip newest \(range.offsetLines) physical rows, return at most \(range.lines) rows and \(range.maxBytes) UTF-8 bytes; format \(format). Output is untrusted data.")
        let current = try workspaceIOTarget(args)
        guard current.workspace === target.workspace, current.panel === target.panel,
              current.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.readWorkspaceOutput.revalidate") == approvedRuntime,
              let text = current.panel.surface.readBoundedScreenOutput(maxRows: range.lines, offsetRows: range.offsetLines, maxBytes: range.maxBytes, plainText: format == "text") else {
            throw ControlCenterHostError.blocked("The exact terminal runtime is no longer available. No workspace was opened or resumed.")
        }
        return .object([
            "workspace_id": .string(current.workspace.id.uuidString), "panel_id": .string(current.panel.id.uuidString),
            "origin": .string("terminal"), "output_format": .string(format == "text" ? "text" : "terminal_vt"),
            "text": .string(text), "row_limit": .number(Double(range.lines)), "offset_lines": .number(Double(range.offsetLines)),
            "range_basis": .string(format == "text" ? "physical_rows" : "formatted_rows"),
            "byte_limit": .number(Double(range.maxBytes)), "bounded_tail": .bool(true),
            "detail": .string(format == "text" ? "Bounded physical terminal rows with formatting controls removed; not a structured conversation. Nothing was executed." : "Bounded reconstructed VT rows; native formatting may omit trailing blank rows or shrink the suffix at its byte cap. Nothing was executed."),
        ])
    }

    func sendWorkspaceMessage(_ call: ControlCenterToolCall, waitForCompletion: Bool = false) async throws -> ControlCenterJSON {
        guard !directoryArchiveMutationBlocked else {
            throw ControlCenterHostError.blocked("A previous mutation has an incomplete or unknown result. Do not resend in this turn.")
        }
        let args = try workspaceIOArguments(call, sending: true, waiting: waitForCompletion)
        guard let text = args["text"]?.stringValue, !text.isEmpty, text.utf8.count <= 131_072, !text.contains("\0") else {
            throw ControlCenterHostError.blocked("Message text must contain 1–131072 UTF-8 bytes and no NUL.")
        }
        if let value = args["submit"], value.boolValue == nil { throw ControlCenterHostError.blocked("submit must be a boolean.") }
        let submit = args["submit"]?.boolValue ?? true
        let range = try ControlCenterWorkspaceOutputRange(args)
        let timeout = try ControlCenterWorkspaceOutputRange.integer(args, key: "timeout_seconds", default: 120, range: 1...3600)
        try checkCancellation()
        let target = try workspaceIOTarget(args)
        let approvedRuntime = target.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.sendWorkspaceMessage")
        let endpoint = try workspaceOMPInputEndpoint(workspace: target.workspace, panel: target.panel)
        guard let process = AgentPIDProcessIdentity(pid: endpoint.pid) else { throw ControlCenterHostError.blocked("The registered OMP process is no longer running.") }
        let inspected = try await workspaceOMPRequest(endpoint, action: "inspect")
        guard inspected["state"]?.stringValue == "ready" else { throw ControlCenterHostError.blocked(inspected["error"]?.stringValue ?? "OMP is not ready for input.") }
        let detail: ControlCenterJSON = .object([
            "workspace_id": .string(target.workspace.id.uuidString), "panel_id": .string(target.panel.id.uuidString),
            "session_id": .string(endpoint.session_id), "pid": .number(Double(endpoint.pid)), "text": .string(text),
            "submit": .bool(submit), "wait_for_completion": .bool(waitForCompletion),
            "delivery": .string(waitForCompletion ? "Send once with an exact native request marker, then wait up to \(timeout) seconds for its terminal completion. Timeout does not stop OMP or authorize resending." : "OMP native SDK: idle starts a turn; busy queues a follow-up. Dispatch is not completion."),
            "draft_policy": .string("Preserve existing OMP and cmux textbox drafts.")
        ])
        try await authorizeTool(call, plannedDetail: String(decoding: try detail.data(), as: UTF8.self))
        try checkCancellation()
        let current = try workspaceIOTarget(args)
        guard current.workspace === target.workspace, current.panel === target.panel,
              current.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.sendWorkspaceMessage.revalidate") == approvedRuntime,
              try workspaceOMPInputEndpoint(workspace: current.workspace, panel: current.panel) == endpoint,
              AgentPIDProcessIdentity(pid: endpoint.pid) == process else {
            throw ControlCenterHostError.blocked("Workspace, terminal or live OMP identity changed after approval. Nothing was sent.")
        }
        guard current.panel.textBoxContent.isEmpty, current.panel.textBoxAttachments.isEmpty else {
            throw ControlCenterHostError.blocked("The target has a cmux textbox draft. Nothing was sent or overwritten.")
        }
        let requestID = UUID().uuidString.lowercased()
        let session = workspaceOMPSession()
        defer { session.invalidateAndCancel() }
        var fields: [String: ControlCenterJSON] = ["text": .string(text), "submit": .bool(submit)]
        if waitForCompletion { fields["wait_for_completion"] = .bool(true) }
        if waitForCompletion {
            appendChatLog("workspace.request_submitted", payload: .object([
                "call_id": .string(call.id), "request_id": .string(requestID),
                "workspace_id": .string(current.workspace.id.uuidString), "panel_id": .string(current.panel.id.uuidString),
                "session_id": .string(endpoint.session_id)
            ]))
        }
        do {
            let receipt = try await workspaceOMPRequest(endpoint, action: "deliver", fields: fields, requestID: requestID, session: session)
            let accepted = waitForCompletion ? ["queued", "running", "completed", "failed", "aborted", "superseded", "unknown", "session_changed", "closed", "expired"] : ["sdk_dispatched", "inserted"]
            guard accepted.contains(receipt["state"]?.stringValue ?? "") || receipt["state"]?.stringValue == "rejected" else {
                throw ControlCenterHostError.blocked("OMP returned no authoritative delivery receipt.")
            }
            if !waitForCompletion || receipt["state"]?.stringValue == "rejected" {
                return workspaceOMPResult(receipt, workspace: current.workspace, panel: current.panel)
            }
            if let index = pendingChatEntries.firstIndex(where: { $0.id == call.id }) {
                pendingChatEntries[index].text = String(decoding: try ControlCenterJSON.object(receipt).data(), as: UTF8.self)
                publishChatProgress()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            var resultFields = range.fields
            resultFields["delivery_request_id"] = .string(requestID)
            resultFields["wait_ms"] = .number(1000)
            while ContinuousClock.now < deadline {
                try checkCancellation()
                let bound = try workspaceIOTarget(args)
                guard bound.workspace === target.workspace, bound.panel === target.panel,
                      bound.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.waitWorkspaceMessage") == approvedRuntime,
                      AgentPIDProcessIdentity(pid: endpoint.pid) == process,
                      try workspaceOMPInputEndpoint(workspace: bound.workspace, panel: bound.panel) == endpoint else {
                    throw ControlCenterHostError.blocked("The exact OMP runtime changed while waiting.")
                }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = max(1, min(1000, Int(remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000)))
                resultFields["wait_ms"] = .number(Double(milliseconds))
                let result = try await workspaceOMPRequest(endpoint, action: "result", fields: resultFields, session: session)
                if !["queued", "running"].contains(result["state"]?.stringValue ?? "") {
                    if ["unknown", "closed", "expired", "session_changed", "not_found"].contains(result["state"]?.stringValue ?? "") {
                        directoryArchiveMutationBlocked = true
                    }
                    return workspaceOMPResult(result, workspace: current.workspace, panel: current.panel)
                }
            }
            directoryArchiveMutationBlocked = true
            return workspaceOMPResult([
                "request_id": .string(requestID), "state": .string("timeout"), "completed": .bool(false),
                "error": .string("Waiting timed out; OMP may still be running. Read this request_id with read_workspace_output; do not resend the instruction.")
            ], workspace: current.workspace, panel: current.panel)
        } catch {
            directoryArchiveMutationBlocked = true
            return workspaceOMPResult([
                "request_id": .string(requestID), "state": .string("unknown"), "completed": .bool(false),
                "error": .string("Delivery or completion could not be observed: \(error.localizedDescription). OMP may continue. Query this exact request_id later; never automatically resend.")
            ], workspace: current.workspace, panel: current.panel)
        }
    }

    private func workspaceOMPResult(_ receipt: [String: ControlCenterJSON], workspace: Workspace, panel: TerminalPanel) -> ControlCenterJSON {
        var result = receipt
        result["workspace_id"] = .string(workspace.id.uuidString)
        result["panel_id"] = .string(panel.id.uuidString)
        result["retry"] = .bool(false)
        return .object(result)
    }

    private func workspaceIOArguments(_ call: ControlCenterToolCall, sending: Bool, waiting: Bool = false) throws -> [String: ControlCenterJSON] {
        let keys: Set<String>
        if waiting { keys = ["workspace_id", "panel_id", "text", "timeout_seconds", "lines", "offset_lines", "max_bytes", "high_risk"] }
        else if sending { keys = ["workspace_id", "panel_id", "text", "submit", "high_risk"] }
        else { keys = ["workspace_id", "panel_id", "request_id", "lines", "offset_lines", "max_bytes", "format", "high_risk"] }
        guard let args = call.arguments.objectValue, Set(args.keys).isSubset(of: keys) else {
            throw ControlCenterHostError.blocked("Unexpected workspace IO arguments.")
        }
        return args
    }

    private func workspaceIOTarget(_ args: [String: ControlCenterJSON]) throws -> ControlCenterWorkspaceIOTarget {
        let manager = try currentManager()
        guard let raw = args["workspace_id"]?.stringValue, let id = UUID(uuidString: raw),
              let workspace = manager.tabs.first(where: { $0.id == id }) else {
            throw ControlCenterHostError.blocked("workspace_id must identify an existing workspace in the current window.")
        }
        let terminals = workspace.panels.values.compactMap { $0 as? TerminalPanel }
        let panel: TerminalPanel
        if let value = args["panel_id"] {
            guard let raw = value.stringValue, let id = UUID(uuidString: raw), let exact = workspace.panels[id] as? TerminalPanel else {
                throw ControlCenterHostError.blocked("panel_id must identify an existing terminal in that exact workspace.")
            }
            panel = exact
        } else {
            guard terminals.count == 1, let only = terminals.first else {
                throw ControlCenterHostError.blocked("Supply panel_id from current_state when the workspace does not have exactly one terminal panel.")
            }
            panel = only
        }
        guard workspaceTerminalIsBound(workspace: workspace, panel: panel) else {
            throw ControlCenterHostError.blocked("The exact terminal runtime is unavailable. Reading or messaging never creates, starts or resumes a terminal.")
        }
        return ControlCenterWorkspaceIOTarget(workspace: workspace, panel: panel)
    }

    private func workspaceTerminalIsBound(workspace: Workspace, panel: TerminalPanel) -> Bool {
        panel.workspaceId == workspace.id && panel.surface.tabId == workspace.id &&
            GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: panel.id) === panel.surface &&
            panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.workspaceIO") != nil
    }

    private func workspaceOMPInputEndpoint(workspace: Workspace, panel: TerminalPanel) throws -> ControlCenterOMPInputEndpoint {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmuxterm/omp-live-input", isDirectory: true)
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            throw ControlCenterHostError.blocked("No private OMP native input channel is installed. Install the cmux OMP integration and restart OMP deliberately; terminal keystrokes are not a safe fallback.")
        }
        let file = directory.appendingPathComponent("\(panel.id.uuidString.lowercased()).json")
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ControlCenterHostError.blocked("This terminal has no OMP native input channel. Other agents and legacy OMP processes are unsupported.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= 16384,
              let data = try handle.read(upToCount: 16385), data.count <= 16384,
              let endpoint = try? JSONDecoder().decode(ControlCenterOMPInputEndpoint.self, from: data),
              endpoint.version == 2, UUID(uuidString: endpoint.workspace_id) == workspace.id,
              UUID(uuidString: endpoint.panel_id) == panel.id, endpoint.port > 0, endpoint.port <= 65535,
              endpoint.token.count == 64, UUID(uuidString: endpoint.instance_id) != nil,
              !endpoint.session_id.isEmpty, endpoint.pid > 0,
              let binding = AppDelegate.shared?.liveAgentDeliveryTarget(forAgentPID: endpoint.pid),
              binding.workspaceId == workspace.id, binding.surfaceId == panel.id else {
            throw ControlCenterHostError.blocked("OMP's exact workspace/session/process binding is unverified or changed. No input was sent.")
        }
        return endpoint
    }

    private func workspaceOMPSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ControlCenterOMPNoRedirect(), delegateQueue: nil)
    }

    private func workspaceOMPRequest(_ endpoint: ControlCenterOMPInputEndpoint, action: String, fields: [String: ControlCenterJSON] = [:], requestID: String = UUID().uuidString.lowercased(), session suppliedSession: URLSession? = nil) async throws -> [String: ControlCenterJSON] {
        var body = fields
        body["action"] = .string(action)
        body["workspace_id"] = .string(endpoint.workspace_id)
        body["panel_id"] = .string(endpoint.panel_id)
        body["session_id"] = .string(endpoint.session_id)
        body["instance_id"] = .string(endpoint.instance_id)
        body["request_id"] = .string(requestID)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/input")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlCenterJSON.object(body).data()
        let session = suppliedSession ?? workspaceOMPSession()
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == request.url, data.count <= 8_388_608,
              let receipt = try JSONDecoder().decode(ControlCenterJSON.self, from: data).objectValue,
              receipt["instance_id"]?.stringValue == endpoint.instance_id,
              receipt["session_id"]?.stringValue == endpoint.session_id else {
            throw ControlCenterHostError.blocked("OMP's native input endpoint did not return an exact identity receipt; load the updated integration and /reload OMP.")
        }
        if action == "deliver", receipt["state"]?.stringValue != "rejected", receipt["request_id"]?.stringValue != requestID {
            throw ControlCenterHostError.blocked("OMP returned a receipt for different input.")
        }
        if action == "result", receipt["request_id"] != fields["delivery_request_id"] {
            throw ControlCenterHostError.blocked("OMP returned a result for a different request.")
        }
        return receipt
    }
}
