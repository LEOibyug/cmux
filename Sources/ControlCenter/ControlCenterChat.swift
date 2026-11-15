import AppKit
import CmuxControlCenter
import Foundation

struct ControlCenterChatTurn: Identifiable {
    let id: UUID
    let prompt: String
    var attachments: [ControlCenterChatAttachment] = []
    var entries: [ControlCenterChatEntry] = []
    var response = ""
    var operation: ControlCenterOperation?
    var error: String?
    var contextBefore: [ControlCenterJSON] = []
}

struct ControlCenterChatEntry: Identifiable, Equatable {
    let id: String
    let kind: String
    var title = ""
    var text = ""
    var status = ""
    var arguments = ""
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

    func receiveModelEvent(_ event: ControlCenterModelEvent, operationID: UUID) {
        guard isRunning, !cancelled, operation?.id == operationID else { return }
        switch event {
        case .requestSubmitted(let body):
            appendChatLog("model.request", payload: body)
        case .responseStarted:
            appendChatLog("model.response_started", payload: .object([:]))
        case .textDelta(let delta):
            pendingChatText.append(delta)
            appendChatText(delta, kind: "text")
        case .reasoningDelta(let delta):
            appendChatText(delta, kind: "reasoning")
        case .toolCall(let id, let name, let arguments):
            if let index = pendingChatEntries.firstIndex(where: { $0.id == id && $0.kind == "tool" }) {
                pendingChatEntries[index].arguments = arguments
            } else {
                pendingChatEntries.append(ControlCenterChatEntry(id: id, kind: "tool", title: name, status: "preparing", arguments: arguments))
            }
        }
        scheduleChatProgress()
        scheduleChatLogWrite()
    }

    private func appendChatText(_ text: String, kind: String) {
        if let index = pendingChatEntries.indices.last, pendingChatEntries[index].kind == kind {
            pendingChatEntries[index].text.append(text)
        } else {
            pendingChatEntries.append(ControlCenterChatEntry(id: UUID().uuidString, kind: kind, text: text))
        }
    }

    private func scheduleChatProgress() {
        guard chatProgressTask == nil else { return }
        chatProgressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            self.chatProgressTask = nil
            self.publishChatProgress()
        }
    }

    func publishChatProgress() {
        chatProgressTask?.cancel()
        chatProgressTask = nil
        chatEntries = pendingChatEntries
        streamingText = pendingChatText
    }

    func beginChatTool(_ call: ControlCenterToolCall) {
        activeChatToolID = call.id
        let arguments = (try? String(decoding: call.arguments.data(), as: UTF8.self)) ?? ""
        if let index = pendingChatEntries.firstIndex(where: { $0.id == call.id && $0.kind == "tool" }) {
            pendingChatEntries[index].arguments = arguments
            pendingChatEntries[index].status = "running"
        } else {
            pendingChatEntries.append(ControlCenterChatEntry(id: call.id, kind: "tool", title: call.name, status: "running", arguments: arguments))
        }
        appendChatLog("tool.started", payload: .object(["call_id": .string(call.id), "name": .string(call.name), "arguments": call.arguments]))
        publishChatProgress()
    }

    func finishChatTool(_ call: ControlCenterToolCall, result: ControlCenterJSON, stepStart: Int) {
        let failedStep = operation?.steps.dropFirst(stepStart).last(where: { $0.status != .success })
        let status = failedStep?.status.rawValue ?? (result.objectValue?["error"] == nil ? "success" : "blocked")
        if let index = pendingChatEntries.firstIndex(where: { $0.id == call.id && $0.kind == "tool" }) {
            pendingChatEntries[index].status = status
            pendingChatEntries[index].text = (try? String(decoding: result.data(), as: UTF8.self)) ?? ""
        }
        appendChatLog("tool.finished", payload: .object(["call_id": .string(call.id), "status": .string(status), "result": result]))
        activeChatToolID = nil
        publishChatProgress()
    }

    func setChatToolStatus(_ status: String) {
        guard let id = activeChatToolID,
              let index = pendingChatEntries.firstIndex(where: { $0.id == id && $0.kind == "tool" }) else { return }
        pendingChatEntries[index].status = status
        publishChatProgress()
    }

    func sendChat() {
        let prompt = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, activeChatTurnID == nil, !chatImagesLoading,
              !prompt.isEmpty || !chatAttachments.isEmpty else { return }
        if prompt == "/clear" || prompt == "/new" {
            clearChat()
            return
        }
        guard prompt.utf8.count <= 16_384 else {
            chatComposerError = ControlCenterStrings.text("requestTooLong")
            return
        }
        if let id = chatEditingTurnID, let index = chatTurns.firstIndex(where: { $0.id == id }) {
            lastContext = chatTurns[index].contextBefore
            chatTurns.removeSubrange(index...)
        }
        let attachments = chatAttachments
        if !prompt.isEmpty { chatInputHistory.append(prompt) }
        chatHistoryIndex = nil
        chatEditingTurnID = nil
        chatDraft = ""
        chatAttachments = []
        chatComposerError = nil
        Task { await submit(prompt, followUp: true, attachments: attachments) }
    }

    func finishChatTurn() async {
        publishChatProgress()
        guard let id = activeChatTurnID,
              let index = chatTurns.firstIndex(where: { $0.id == id }) else { return }
        for entryIndex in pendingChatEntries.indices where ["preparing", "running", "waiting"].contains(pendingChatEntries[entryIndex].status) {
            pendingChatEntries[entryIndex].status = cancelled ? "cancelled" : "blocked"
        }
        chatEntries = pendingChatEntries
        chatTurns[index].entries = pendingChatEntries
        chatTurns[index].response = displayedOutput
        chatTurns[index].operation = operation
        chatTurns[index].error = error
        completeInterruptedChatCalls()
        appendChatLog("assistant.finished", payload: .object([
            "turn_id": .string(id.uuidString), "text": .string(displayedOutput),
            "cancelled": .bool(cancelled), "error": error.map(ControlCenterJSON.string) ?? .null,
            "entries": .array(pendingChatEntries.map(chatEntryJSON))
        ]))
        activeChatTurnID = nil
        activeChatToolID = nil
        await persistChatConversation()
    }

    func completeInterruptedChatCalls() {
        let answered = Set(lastContext.compactMap { value -> String? in
            guard value.objectValue?["type"]?.stringValue == "function_call_output" else { return nil }
            return value.objectValue?["call_id"]?.stringValue
        })
        for value in lastContext {
            guard value.objectValue?["type"]?.stringValue == "function_call",
                  let id = value.objectValue?["call_id"]?.stringValue, !answered.contains(id) else { continue }
            lastContext.append(.object([
                "type": .string("function_call_output"), "call_id": .string(id),
                "output": .string("{\"error\":\"Operation interrupted without an observed tool result; outcome may be unknown. Inspect state before any new action.\",\"retry\":false}")
            ]))
        }
    }

    func clearChat() {
        guard !isRunning, activeChatTurnID == nil else { return }
        resetContext()
        chatTurns = []
        chatDraft = ""
        chatAttachments = []
        chatEntries = []
        pendingChatEntries = []
        pendingChatText = ""
        chatEditingTurnID = nil
        chatHistoryIndex = nil
        chatComposerError = nil
        chatDraftGeneration += 1
        chatImageImportCount = 0
        chatImagesLoading = false
        operation = nil
        error = nil
        chatConversationID = UUID()
        chatConversationCreatedAt = Date()
        appendChatLog("conversation.started", payload: .object([:]))
        Task { await persistChatConversation() }
    }

    func regenerateChatTurn(_ id: UUID) {
        guard !isRunning, activeChatTurnID == nil,
              let index = chatTurns.firstIndex(where: { $0.id == id }) else { return }
        let turn = chatTurns[index]
        lastContext = turn.contextBefore
        chatTurns.removeSubrange(index...)
        chatEditingTurnID = nil
        appendChatLog("user.regenerated", payload: .object(["turn_id": .string(id.uuidString)]))
        Task { await submit(turn.prompt, followUp: true, attachments: turn.attachments) }
    }

    func editChatTurn(_ id: UUID) {
        guard !isRunning, activeChatTurnID == nil,
              let turn = chatTurns.first(where: { $0.id == id }) else { return }
        if chatEditingTurnID == nil {
            draftBeforeChatEdit = chatDraft
            attachmentsBeforeChatEdit = chatAttachments
        }
        chatDraftGeneration += 1
        chatImagesLoading = false
        chatImageImportCount = 0
        chatEditingTurnID = id
        chatDraft = turn.prompt
        chatAttachments = turn.attachments
        chatComposerError = nil
    }

    func cancelChatEdit() {
        guard !isRunning else { return }
        chatDraftGeneration += 1
        chatImageImportCount = 0
        chatImagesLoading = false
        chatEditingTurnID = nil
        chatDraft = draftBeforeChatEdit
        chatAttachments = attachmentsBeforeChatEdit
        chatComposerError = nil
    }

    func recallChatInput(_ direction: Int) {
        guard !chatInputHistory.isEmpty, chatEditingTurnID == nil else { return }
        let next: Int
        if let current = chatHistoryIndex {
            next = current + direction
        } else {
            guard direction < 0 else { return }
            recalledChatDraft = chatDraft
            next = chatInputHistory.count - 1
        }
        guard next >= 0 else { return }
        if next >= chatInputHistory.count {
            chatDraft = recalledChatDraft
            chatHistoryIndex = nil
        } else {
            chatDraft = chatInputHistory[next]
            chatHistoryIndex = next
        }
    }

    func selectChatModel(_ model: String) {
        guard !isRunning else { return }
        connection.model = model
        saveChatConnectionSelection()
    }

    func selectChatReasoningEffort(_ effort: String) {
        guard !isRunning else { return }
        connection.reasoningEffort = effort == "auto" ? nil : effort
        saveChatConnectionSelection()
    }

    private func saveChatConnectionSelection() {
        let value = connection
        Task {
            do { try await localStore().saveConnection(value) }
            catch { chatComposerError = error.localizedDescription }
        }
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
        appendChatLog("tool.approval", payload: .object([
            "call_id": activeChatToolID.map(ControlCenterJSON.string) ?? .null, "allowed": .bool(allowed)
        ]))
        setChatToolStatus(allowed ? "running" : "blocked")
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
        setChatToolStatus("waiting")
        appendChatLog("tool.approval_requested", payload: .object(["call_id": .string(call.id), "detail": .string(detail)]))
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
            let name = request.name.isEmpty ? "" : "name: \(request.name)\n"
            return "\(ControlCenterStrings.text("commandWorkspaceDisclosure"))\n\n\(name)command:\n\(request.command)\n\ncwd: \(request.directory)"
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
