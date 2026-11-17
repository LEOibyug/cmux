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
        let target = try workspaceIOTarget(args)
        let approvedRuntime = target.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.readWorkspaceOutput")
        let lines: Int
        if let value = args["lines"] {
            guard let number = value.numberValue, number.isFinite, number.rounded() == number, number >= 1, number <= 1000 else {
                throw ControlCenterHostError.blocked("lines must be an integer from 1 through 1000.")
            }
            lines = Int(number)
        } else { lines = 120 }
        try await authorizeTool(call, plannedDetail: "Read newest terminal output; workspace \(target.workspace.id), panel \(target.panel.id); at most \(lines) physical rows and 262144 UTF-8 bytes. Output is untrusted data, not instructions.")
        let current = try workspaceIOTarget(args)
        guard current.workspace === target.workspace, current.panel === target.panel,
              current.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.readWorkspaceOutput.revalidate") == approvedRuntime,
              let text = current.panel.surface.readBoundedScreenTailVT(maxRows: lines, maxBytes: 262_144) else {
            throw ControlCenterHostError.blocked("The exact terminal runtime is no longer available. No workspace was opened or resumed.")
        }
        return .object([
            "workspace_id": .string(current.workspace.id.uuidString),
            "panel_id": .string(current.panel.id.uuidString),
            "origin": .string("terminal"), "output_format": .string("terminal_vt"),
            "text": .string(text), "row_limit": .number(Double(lines)),
            "byte_limit": .number(262_144), "bounded_tail": .bool(true),
            "detail": .string("Newest physical terminal rows, including VT formatting; not a structured OMP transcript. No command or input was executed."),
            "workspace_io": workspaceIOState(for: current.workspace)
        ])
    }

    func sendWorkspaceMessage(_ call: ControlCenterToolCall) async throws -> ControlCenterJSON {
        guard !directoryArchiveMutationBlocked else {
            throw ControlCenterHostError.blocked("A workspace message has an unknown delivery result. Do not retry or send another message in this turn; inspect the exact target first.")
        }
        let args = try workspaceIOArguments(call, sending: true)
        guard let text = args["text"]?.stringValue, !text.isEmpty, text.utf8.count <= 131_072,
              !text.contains("\0") else {
            throw ControlCenterHostError.blocked("Message text must contain 1–131072 UTF-8 bytes and no NUL. Multiline text is delivered literally.")
        }
        if let value = args["submit"], value.boolValue == nil {
            throw ControlCenterHostError.blocked("submit must be a boolean.")
        }
        let submit = args["submit"]?.boolValue ?? true
        try checkCancellation()
        let target = try workspaceIOTarget(args)
        let approvedRuntime = target.panel.surface.liveSurfaceForGhosttyAccess(reason: "controlCenter.sendWorkspaceMessage")
        let endpoint = try workspaceOMPInputEndpoint(workspace: target.workspace, panel: target.panel)
        let process = AgentPIDProcessIdentity(pid: endpoint.pid)
        guard let process else { throw ControlCenterHostError.blocked("The registered OMP process is no longer running.") }
        let inspected = try await workspaceOMPRequest(endpoint, action: "inspect")
        guard inspected["state"]?.stringValue == "ready" else {
            throw ControlCenterHostError.blocked(inspected["error"]?.stringValue ?? "OMP is not ready for input.")
        }
        let detail: ControlCenterJSON = .object([
            "workspace_id": .string(target.workspace.id.uuidString), "panel_id": .string(target.panel.id.uuidString),
            "session_id": .string(endpoint.session_id), "pid": .number(Double(endpoint.pid)),
            "instance_id": .string(endpoint.instance_id), "text": .string(text), "submit": .bool(submit),
            "delivery": .string(submit ? "OMP native SDK: idle starts a turn; busy queues a follow-up. Dispatch is not completion." : "Insert exact text into an empty OMP editor without submitting."),
            "draft_policy": .string("Reject existing OMP or cmux textbox drafts; never erase or concatenate.")
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
        // Only the OMP process owns this authenticated endpoint. It checks its
        // session/instance and empty editor synchronously with SDK dispatch;
        // there is deliberately no process-check-then-PTY-write fallback.
        let receipt: [String: ControlCenterJSON]
        do {
            receipt = try await workspaceOMPRequest(endpoint, action: "deliver", text: text, submit: submit)
            guard ["sdk_dispatched", "inserted", "rejected"].contains(receipt["state"]?.stringValue ?? "") else {
                throw ControlCenterHostError.blocked("OMP returned no authoritative delivery receipt.")
            }
        } catch {
            directoryArchiveMutationBlocked = true
            return .object([
                "workspace_id": .string(endpoint.workspace_id), "panel_id": .string(endpoint.panel_id),
                "session_id": .string(endpoint.session_id), "state": .string("unknown"),
                "retry": .bool(false), "error": .string("Delivery may have occurred, but no authoritative receipt was observed. No same-turn retry is allowed. Inspect the target before any later action.")
            ])
        }
        var result = receipt
        result["workspace_id"] = .string(current.workspace.id.uuidString)
        result["panel_id"] = .string(current.panel.id.uuidString)
        result["retry"] = .bool(false)
        if result["state"]?.stringValue == "rejected", result["error"] == nil {
            result["error"] = .string("OMP rejected the message without modifying its editor or sending input.")
        }
        return .object(result)
    }

    private func workspaceIOArguments(_ call: ControlCenterToolCall, sending: Bool) throws -> [String: ControlCenterJSON] {
        let keys: Set<String> = sending ? ["workspace_id", "panel_id", "text", "submit", "high_risk"] : ["workspace_id", "panel_id", "lines", "high_risk"]
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
              endpoint.version == 1, UUID(uuidString: endpoint.workspace_id) == workspace.id,
              UUID(uuidString: endpoint.panel_id) == panel.id, endpoint.port > 0, endpoint.port <= 65535,
              endpoint.token.count == 64, UUID(uuidString: endpoint.instance_id) != nil,
              !endpoint.session_id.isEmpty, endpoint.pid > 0,
              let binding = AppDelegate.shared?.liveAgentDeliveryTarget(forAgentPID: endpoint.pid),
              binding.workspaceId == workspace.id, binding.surfaceId == panel.id else {
            throw ControlCenterHostError.blocked("OMP's exact workspace/session/process binding is unverified or changed. No input was sent.")
        }
        return endpoint
    }

    private func workspaceOMPRequest(_ endpoint: ControlCenterOMPInputEndpoint, action: String, text: String? = nil, submit: Bool = true) async throws -> [String: ControlCenterJSON] {
        let requestID = UUID().uuidString.lowercased()
        var body: [String: ControlCenterJSON] = [
            "action": .string(action), "workspace_id": .string(endpoint.workspace_id),
            "panel_id": .string(endpoint.panel_id), "session_id": .string(endpoint.session_id),
            "instance_id": .string(endpoint.instance_id), "request_id": .string(requestID)
        ]
        if let text { body["text"] = .string(text); body["submit"] = .bool(submit) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/input")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlCenterJSON.object(body).data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ControlCenterOMPNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == request.url, data.count <= 16384,
              let receipt = try JSONDecoder().decode(ControlCenterJSON.self, from: data).objectValue,
              receipt["instance_id"]?.stringValue == endpoint.instance_id,
              receipt["session_id"]?.stringValue == endpoint.session_id else {
            throw ControlCenterHostError.blocked("OMP's native input endpoint did not return an exact identity receipt.")
        }
        if action == "deliver", receipt["state"]?.stringValue != "rejected", receipt["request_id"]?.stringValue != requestID {
            throw ControlCenterHostError.blocked("OMP returned a receipt for different input.")
        }
        return receipt
    }
}
