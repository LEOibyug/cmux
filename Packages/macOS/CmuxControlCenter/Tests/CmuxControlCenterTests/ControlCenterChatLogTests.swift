import Foundation
import Testing
import CmuxControlCenter

@Suite("Control Center conversation logs")
struct ControlCenterChatLogTests {
    @Test func snapshotsAndOrderedAtomicEventBatchesSurviveReopening() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1234.5)
        var conversation = ControlCenterConversation(
            title: "Persistent conversation", createdAt: timestamp, updatedAt: timestamp,
            snapshot: .object([
                "messages": .array([.object(["text": .string("Exact 中文\ncontent"), "attachment": .string("AAECAw==")])]),
                "context": .object(["model": .string("local-model")])
            ])
        )
        let request = ControlCenterChatLogEvent(createdAt: timestamp, kind: "request", payload: .object(["body": .string("full request")]))
        let response = ControlCenterChatLogEvent(createdAt: timestamp, kind: "response", payload: .object(["output": .string("full output")]))
        let final = ControlCenterChatLogEvent(createdAt: timestamp.addingTimeInterval(-1), kind: "tool", payload: .object(["arguments": .string("{}"), "result": .string("complete")]))
        conversation.snapshot = .object(["previous": conversation.snapshot, "completed": .bool(true)])
        try await populate(directory, conversation: conversation, batches: [[request, response], [final]])

        let reopened = try ControlCenterStore(directory: directory)
        #expect(try await reopened.latestConversation() == conversation)
        #expect(try await reopened.conversation(id: conversation.id) == conversation)
        #expect(try await reopened.chatEvents(conversationID: conversation.id) == [request, response, final])

        let wouldBePartial = ControlCenterChatLogEvent(kind: "error", payload: .string("must roll back"))
        await #expect(throws: ControlCenterStoreError.self) {
            try await reopened.appendChatEvents(conversationID: conversation.id, events: [wouldBePartial, request])
        }
        #expect(try await reopened.chatEvents(conversationID: conversation.id) == [request, response, final])
        let stats = try await reopened.chatLogStatistics()
        #expect(stats.conversationCount == 2)
        #expect(stats.eventCount == 3)
    }

    @Test func clearingReclaimsOnlyLogsAndAllowsNewConversations() async throws {
        let directory = controlCenterTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControlCenterStore(directory: directory)
        let favorite = ControlCenterTarget(name: "Keep", kind: .directory, path: "/project")
        try await store.saveFavorite(favorite)
        try await store.saveCollection(ControlCenterCollection(name: "Keep collection", items: [favorite]))
        try await store.savePreference(ControlCenterPreference(key: "keep", value: "yes", scope: "/project"))
        try await store.saveOperation(ControlCenterOperation(title: "Keep receipt"))
        let connection = ControlCenterConnection(model: "private-model", apiKey: "private-log-test-key")
        try await store.saveConnection(connection)
        let original = try await store.snapshot()
        let connectionURL = directory.appendingPathComponent("connection.json")
        let connectionBytes = try Data(contentsOf: connectionURL)
        let conversation = ControlCenterConversation(title: "Remove", snapshot: .string(String(repeating: "private transcript", count: 20_000)))
        try await store.saveConversation(conversation)
        try await store.appendChatEvents(conversationID: conversation.id, events: [ControlCenterChatLogEvent(kind: "response", payload: conversation.snapshot)])
        let before = try await store.chatLogStatistics()
        #expect(before.storageBytes > 300_000)
        let logURL = directory.appendingPathComponent("chat-logs.sqlite3")
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(before.storageBytes == (attributes[.size] as? NSNumber)?.int64Value)
        #expect(try Data(contentsOf: logURL).range(of: Data(connection.apiKey.utf8)) == nil)

        try await store.clearChatLogs()
        #expect(try await store.chatLogStatistics() == ControlCenterChatLogStatistics(conversationCount: 0, eventCount: 0, storageBytes: 0))
        #expect(try await store.latestConversation() == nil)
        #expect(try await store.chatEvents(conversationID: conversation.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(try Data(contentsOf: connectionURL) == connectionBytes)
        let reopened = try ControlCenterStore(directory: directory)
        #expect(try await reopened.snapshot() == original)
        #expect(try await reopened.connection() == connection)
        #expect(try await reopened.latestConversation() == nil)
        try await reopened.saveConversation(conversation)
        #expect(try await reopened.latestConversation() == conversation)
        try await reopened.clearChatLogs()
    }

    private func populate(_ directory: URL, conversation: ControlCenterConversation, batches: [[ControlCenterChatLogEvent]]) async throws {
        let store = try ControlCenterStore(directory: directory)
        let older = ControlCenterConversation(title: "Older", updatedAt: conversation.updatedAt.addingTimeInterval(-10), snapshot: .null)
        var initial = conversation
        initial.snapshot = .null
        initial.updatedAt = conversation.updatedAt.addingTimeInterval(-20)
        try await store.saveConversation(initial)
        try await store.saveConversation(conversation)
        try await store.saveConversation(older)
        for batch in batches {
            try await store.appendChatEvents(conversationID: conversation.id, events: batch)
        }
    }
}
