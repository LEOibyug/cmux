import CmuxControlCenter
import Foundation

struct ControlCenterChatTurn: Identifiable {
    let id: UUID
    let prompt: String
    var response = ""
    var operation: ControlCenterOperation?
    var error: String?
}

enum ControlCenterAccessMode: String, CaseIterable {
    case ask, fullAccess

    static let defaultsKey = "controlCenter.accessMode"
    static var saved: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .ask
    }
    var title: String { ControlCenterStrings.text(rawValue) }
}

struct ControlCenterApproval: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

extension ControlCenterCoordinator {
    var displayedOutput: String {
        if output.isEmpty { return streamingText }
        if streamingText.isEmpty { return output }
        return output + "\n\n" + streamingText
    }

    func receiveModelText(_ delta: String, operationID: UUID) {
        guard isRunning, !cancelled, operation?.id == operationID else { return }
        streamingText.append(delta)
    }

    func sendChat() {
        let prompt = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, activeChatTurnID == nil, !prompt.isEmpty else { return }
        guard prompt.utf8.count <= 16_384 else {
            error = ControlCenterStrings.text("requestTooLong")
            return
        }
        chatDraft = ""
        Task { await submit(prompt, followUp: true) }
    }

    func finishChatTurn() {
        guard let id = activeChatTurnID,
              let index = chatTurns.firstIndex(where: { $0.id == id }) else { return }
        let response = displayedOutput
        chatTurns[index].response = response
        chatTurns[index].operation = operation
        let receipts = operation?.steps.map { "\($0.title): \($0.status.rawValue) — \($0.detail)" }.joined(separator: "\n") ?? ""
        var context = response
        if !receipts.isEmpty { context += "\nActual operation receipts:\n" + receipts }
        if let error { context += "\nOperation error: " + error }
        lastContext.append(.object(["role": .string("user"), "content": .string(chatTurns[index].prompt)]))
        lastContext.append(.object(["role": .string("assistant"), "content": .string(context)]))
        chatTurns[index].error = error
        activeChatTurnID = nil
    }

    func clearChat() {
        guard !isRunning, activeChatTurnID == nil else { return }
        resetContext()
        chatTurns = []
        chatDraft = ""
        operation = nil
        error = nil
    }

    static func isReadOnlyModelTool(_ name: String) -> Bool {
        switch name {
        case "search_sessions", "list_saved", "current_state", "list_settings", "memory_list", "help": return true
        default: return false
        }
    }

    func resolveApproval(_ allowed: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingApproval = nil
        continuation?.resume(returning: allowed)
    }

    func authorizeTool(_ call: ControlCenterToolCall) async throws {
        try checkCancellation()
        guard !Self.isReadOnlyModelTool(call.name), accessMode == .ask else { return }
        try await refreshSnapshot()
        let detail = try approvalDetail(call)
        let request = ControlCenterApproval(
            title: ControlCenterStrings.text("approve." + call.name),
            detail: detail
        )
        ControlCenterPresentation.show()
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuation = continuation
                pendingApproval = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.pendingApproval?.id == request.id { self?.resolveApproval(false) }
            }
        }
        try checkCancellation()
        guard approved else { throw ControlCenterHostError.blocked(ControlCenterStrings.text("approvalDeclined")) }
        try await refreshSnapshot()
        guard try approvalDetail(call) == detail else {
            throw ControlCenterHostError.blocked(ControlCenterStrings.text("approvalChanged"))
        }
    }

    private func approvalDetail(_ call: ControlCenterToolCall) throws -> String {
        let args = call.arguments.objectValue ?? [:]
        if call.name == "bash" {
            let request = try bashArguments(call.arguments)
            return "\(ControlCenterStrings.text("bashApprovalDisclosure"))\n\ncommand:\n\(request.command)\n\ncwd: \(request.directory)\ntimeout_seconds: \(request.timeout)"
        }
        if call.name == "open_command_workspace" {
            let request = try commandWorkspaceArguments(call.arguments)
            return "\(ControlCenterStrings.text("commandWorkspaceDisclosure"))\n\nname: \(request.name)\ncommand:\n\(request.command)\n\ncwd: \(request.directory)"
        }
        var detail: [String: ControlCenterJSON] = ["arguments": call.arguments]
        var identifiers: Set<String> = []
        if let id = args["id"]?.stringValue { identifiers.insert(id.lowercased()) }
        if let id = args["target"]?.objectValue?["favorite_id"]?.stringValue { identifiers.insert(id.lowercased()) }
        for item in args["items"]?.arrayValue ?? [] {
            if let id = item.objectValue?["favorite_id"]?.stringValue { identifiers.insert(id.lowercased()) }
        }
        let favorites = snapshot.favorites.filter { identifiers.contains($0.id.uuidString.lowercased()) }
        let collections = snapshot.collections.filter { identifiers.contains($0.id.uuidString.lowercased()) }
        let preferences = snapshot.preferences.filter { identifiers.contains($0.id.uuidString.lowercased()) }
        if !favorites.isEmpty { detail["favorites"] = try toolJSON(favorites) }
        if !collections.isEmpty { detail["collections"] = try toolJSON(collections) }
        if !preferences.isEmpty { detail["preferences"] = try toolJSON(preferences) }
        if call.name == "open_session", let id = args["session_id"]?.stringValue {
            let source = args["agent_id"]?.stringValue ?? "omp"
            detail["sessions"] = try toolJSON(sessions.filter { $0.agentID == source && $0.sessionID == id })
        }
        if call.name == "set_setting", let id = args["id"]?.stringValue,
           let current = try settingsRows().first(where: { $0.id == id }) {
            detail["current_value"] = current.value
        }
        if call.name == "undo_setting", let receipt = settingUndo.last {
            detail["undo_path"] = .string(receipt.path)
        }
        let object = try JSONSerialization.jsonObject(with: ControlCenterJSON.object(detail).data())
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
