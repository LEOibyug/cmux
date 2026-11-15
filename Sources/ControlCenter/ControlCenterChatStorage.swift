import CmuxControlCenter
import Foundation

extension ControlCenterCoordinator {
    func chatEntryJSON(_ entry: ControlCenterChatEntry) -> ControlCenterJSON {
        .object([
            "id": .string(entry.id), "kind": .string(entry.kind), "title": .string(entry.title),
            "text": .string(entry.text), "status": .string(entry.status), "arguments": .string(entry.arguments)
        ])
    }

    func chatConversationSnapshot() -> ControlCenterConversation {
        let turns = chatTurns.map { turn -> ControlCenterJSON in
            let active = turn.id == activeChatTurnID
            return .object([
                "id": .string(turn.id.uuidString), "prompt": .string(turn.prompt),
                "attachments": .array(turn.attachments.map { .object([
                    "id": .string($0.id.uuidString), "name": .string($0.name), "data_url": .string($0.dataURL)
                ]) }),
                "entries": .array((active ? pendingChatEntries : turn.entries).map(chatEntryJSON)),
                "response": .string(active ? output + (output.isEmpty || pendingChatText.isEmpty ? "" : "\n\n") + pendingChatText : turn.response),
                "operation": (try? toolJSON(active ? operation : turn.operation)) ?? .null,
                "error": (active ? error : turn.error).map(ControlCenterJSON.string) ?? .null,
                "context_before_count": .number(Double(turn.contextBefore.count))
            ])
        }
        return ControlCenterConversation(
            id: chatConversationID,
            title: String((chatTurns.first?.prompt ?? ControlCenterStrings.text("chatNew")).prefix(160)),
            createdAt: chatConversationCreatedAt,
            snapshot: .object([
                "turns": .array(turns), "context": .array(lastContext),
                "active_turn": activeChatTurnID.map { .string($0.uuidString) } ?? .null
            ])
        )
    }

    func appendChatLog(_ kind: String, payload: ControlCenterJSON) {
        let event = ControlCenterChatLogEvent(kind: kind, payload: .object([
            "operation_id": operation.map { .string($0.id.uuidString) } ?? .null,
            "data": payload
        ]))
        pendingChatLogEvents.append((chatConversationID, event))
        pendingChatLogSnapshots[chatConversationID] = chatConversationSnapshot()
        scheduleChatLogWrite()
    }

    func scheduleChatLogWrite() {
        guard chatLogWriteTask == nil, chatLogError == nil else { return }
        chatLogWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.pendingChatLogSnapshots[self.chatConversationID] = self.chatConversationSnapshot()
            await self.writePendingChatLogs()
            self.chatLogWriteTask = nil
        }
    }

    private func writePendingChatLogs() async {
        var unwrittenSnapshots: [UUID: ControlCenterConversation] = [:]
        var unwrittenEvents: [(UUID, ControlCenterChatLogEvent)] = []
        do {
            let store = try localStore()
            while !pendingChatLogSnapshots.isEmpty || !pendingChatLogEvents.isEmpty {
                unwrittenSnapshots = pendingChatLogSnapshots
                unwrittenEvents = pendingChatLogEvents
                pendingChatLogSnapshots = [:]
                pendingChatLogEvents = []
                for snapshot in unwrittenSnapshots.values { try await store.saveConversation(snapshot) }
                unwrittenSnapshots = [:]
                var groups: [UUID: [ControlCenterChatLogEvent]] = [:]
                for (id, event) in unwrittenEvents { groups[id, default: []].append(event) }
                for (id, events) in groups {
                    try await store.appendChatEvents(conversationID: id, events: events)
                    unwrittenEvents.removeAll { $0.0 == id }
                }
            }
            chatLogError = nil
        } catch {
            pendingChatLogSnapshots.merge(unwrittenSnapshots) { current, _ in current }
            pendingChatLogEvents = unwrittenEvents + pendingChatLogEvents
            chatLogError = ControlCenterStrings.text("chatLogWriteFailed") + " " + error.localizedDescription
        }
    }

    func persistChatConversation() async {
        pendingChatLogSnapshots[chatConversationID] = chatConversationSnapshot()
        scheduleChatLogWrite()
        let writer = chatLogWriteTask
        writer?.cancel()
        await writer?.value
    }

    func restoreChatConversation() async {
        guard !chatLogsLoaded else { return }
        chatLogsLoaded = true
        do {
            guard let saved = try await localStore().latestConversation(), let snapshot = saved.snapshot.objectValue else { return }
            guard !isRunning, activeChatTurnID == nil, chatTurns.isEmpty else { return }
            let context = snapshot["context"]?.arrayValue ?? []
            let active = snapshot["active_turn"]?.stringValue
            let turns = try (snapshot["turns"]?.arrayValue ?? []).map { value -> ControlCenterChatTurn in
                guard let row = value.objectValue, let rawID = row["id"]?.stringValue, let id = UUID(uuidString: rawID),
                      let prompt = row["prompt"]?.stringValue else { throw ControlCenterStoreError.invalidRecord }
                let attachments = try (row["attachments"]?.arrayValue ?? []).map { value -> ControlCenterChatAttachment in
                    guard let row = value.objectValue, let id = row["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                          let name = row["name"]?.stringValue, let dataURL = row["data_url"]?.stringValue else {
                        throw ControlCenterStoreError.invalidRecord
                    }
                    return try ControlCenterChatAttachment(id: id, name: name, dataURL: dataURL)
                }
                let entries = try (row["entries"]?.arrayValue ?? []).map { value -> ControlCenterChatEntry in
                    guard let row = value.objectValue, let id = row["id"]?.stringValue, let kind = row["kind"]?.stringValue else {
                        throw ControlCenterStoreError.invalidRecord
                    }
                    let status = row["status"]?.stringValue ?? ""
                    return ControlCenterChatEntry(
                        id: id, kind: kind, title: row["title"]?.stringValue ?? "", text: row["text"]?.stringValue ?? "",
                        status: ["preparing", "running", "waiting"].contains(status) ? "cancelled" : status,
                        arguments: row["arguments"]?.stringValue ?? ""
                    )
                }
                let operation: ControlCenterOperation?
                if let value = row["operation"], value != .null {
                    operation = try JSONDecoder().decode(ControlCenterOperation.self, from: value.data())
                } else { operation = nil }
                return ControlCenterChatTurn(
                    id: id, prompt: prompt, attachments: attachments, entries: entries,
                    response: row["response"]?.stringValue ?? "", operation: operation,
                    error: rawID == active ? ControlCenterStrings.text("chatInterrupted") : row["error"]?.stringValue,
                    contextBefore: Array(context.prefix(Int(row["context_before_count"]?.numberValue ?? 0)))
                )
            }
            chatConversationID = saved.id
            chatConversationCreatedAt = saved.createdAt
            chatTurns = turns
            lastContext = context
            chatInputHistory = turns.map(\.prompt).filter { !$0.isEmpty }
            completeInterruptedChatCalls()
        } catch {
            chatLogError = ControlCenterStrings.text("chatLogReadFailed") + " " + error.localizedDescription
        }
    }

    func refreshChatLogStatistics() async {
        guard !chatLogsLoading else { return }
        chatLogsLoading = true
        defer { chatLogsLoading = false }
        do {
            chatLogError = nil
            await persistChatConversationIfNeeded()
            chatLogStatistics = try await localStore().chatLogStatistics()
        } catch { chatLogError = error.localizedDescription }
    }

    private func persistChatConversationIfNeeded() async {
        if chatLogWriteTask != nil || !pendingChatLogEvents.isEmpty { await persistChatConversation() }
    }

    func clearSavedChatLogs() async {
        guard !isRunning, activeChatTurnID == nil, !chatLogsLoading else { return }
        chatLogsLoading = true
        defer { chatLogsLoading = false }
        await chatLogWriteTask?.value
        do {
            try await localStore().clearChatLogs()
            pendingChatLogEvents = []
            pendingChatLogSnapshots = [:]
            chatTurns = []
            chatEntries = []
            pendingChatEntries = []
            pendingChatText = ""
            chatInputHistory = []
            chatHistoryIndex = nil
            chatEditingTurnID = nil
            resetContext()
            operation = nil
            error = nil
            chatConversationID = UUID()
            chatConversationCreatedAt = Date()
            chatLogError = nil
            chatLogStatistics = try await localStore().chatLogStatistics()
        } catch { chatLogError = error.localizedDescription }
    }
}
