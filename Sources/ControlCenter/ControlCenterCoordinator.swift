import Combine
import CmuxControlCenter
import CmuxAgentSessionStore
import CmuxSettings
import CmuxSettingsUI
import Foundation

struct ControlCenterSetting: Identifiable {
    let id: String
    let title: String
    let detail: String
    let value: ControlCenterJSON
    var options: [String] = []
}

enum ControlCenterHostError: LocalizedError {
    case blocked(String)
    var errorDescription: String? {
        switch self { case .blocked(let reason): return reason }
    }
}

@MainActor
final class ControlCenterCoordinator: ObservableObject {
    static let shared = ControlCenterCoordinator()

    @Published var snapshot = ControlCenterSnapshot()
    @Published var connection = ControlCenterConnection()
    @Published var sessions: [ControlCenterTarget] = []
    @Published var sessionSources: [SessionAgent] = []
    @Published var sessionResultsSourceID: String?
    @Published var managedSessions: [OMPManagedSessionRecord] = []
    @Published var sessionListState = ControlCenterSessionListState.active
    @Published var sessionHasMore = false
    @Published var sessionNextOffset = 0
    @Published var sessionInventoryWarnings: [String] = []
    @Published var sessionResultsState = ControlCenterSessionListState.active
    @Published var isSearchingSessions = false
    @Published var isRefreshingSessions = false
    var sessionQuery = ""
    var sessionSearchContent = false
    var sessionFingerprints: [UUID: String] = [:]
    var sessionParents: [UUID: String] = [:]
    var sessionModifiedAt: [UUID: Date] = [:]
    var sessionJournalRoot: String?
    @Published var sessionSourceID = "omp" {
        didSet {
            if oldValue != sessionSourceID {
                sessionSearchGeneration += 1
                sessions = []
                sessionResultsSourceID = nil
                managedSessions = []
                sessionHasMore = false
                sessionNextOffset = 0
                if sessionSourceID != "omp" { sessionListState = .active }
            }
        }
    }
    @Published var isSavingFavorites = false
    @Published var settings: [ControlCenterSetting] = []
    @Published var models: [String] = []
    @Published var operation: ControlCenterOperation?
    @Published var output = ""
    @Published var error: String?
    @Published var isRunning = false
    @Published var chatTurns: [ControlCenterChatTurn] = []
    @Published var chatDraft = "" {
        didSet { if oldValue != chatDraft { chatHistoryIndex = nil } }
    }
    @Published var chatAttachments: [ControlCenterChatAttachment] = []
    @Published var chatEntries: [ControlCenterChatEntry] = []
    @Published var chatImagesLoading = false
    @Published var chatComposerError: String?
    @Published var chatEditingTurnID: UUID?
    @Published var chatHistoryIndex: Int?
    @Published var chatLogStatistics = ControlCenterChatLogStatistics(conversationCount: 0, eventCount: 0, storageBytes: 0)
    @Published var chatLogError: String?
    @Published var chatLogsLoading = false
    @Published var activeChatTurnID: UUID?
    @Published var chatPresentationID = UUID()
    @Published var streamingText = ""
    @Published var pendingApproval: ControlCenterApproval?
    @Published var accessMode = ControlCenterAccessMode.saved {
        didSet { UserDefaults.standard.set(accessMode.rawValue, forKey: ControlCenterAccessMode.defaultsKey) }
    }

    var settingsRuntime: SettingsRuntime?
    var hasLoadedConnection = false
    var store: ControlCenterStore?
    var sessionIndex: SessionIndexStore?
    var activeTask: Task<Void, Never>?
    var cancelled = false
    var settingUndo: [JSONConfigMutationReceipt] = []
    var lastContext: [ControlCenterJSON] = []
    var contextGeneration = 0
    var collectionResults: [UUID: [UUID: ControlCenterStep]] = [:]
    var sessionTargetIDs: [String: UUID] = [:]
    var sessionSearchGeneration = 0
    var openedTargets: [String: UUID] = [:]
    var approvalContinuation: CheckedContinuation<Bool, Never>?
    var uncertainSessionIDs: Set<String> = []
    var directoryArchiveMutationBlocked = false
    var riskConfirmationDeclined = false
    var pendingChatEntries: [ControlCenterChatEntry] = []
    var pendingChatText = ""
    var chatProgressTask: Task<Void, Never>?
    var activeChatToolID: String?
    var chatInputHistory: [String] = []
    var recalledChatDraft = ""
    var draftBeforeChatEdit = ""
    var attachmentsBeforeChatEdit: [ControlCenterChatAttachment] = []
    var chatImageImportCount = 0
    var chatDraftGeneration = 0
    var chatConversationID = UUID()
    var chatConversationCreatedAt = Date()
    var chatLogsLoaded = false
    var pendingChatLogEvents: [(UUID, ControlCenterChatLogEvent)] = []
    var pendingChatLogSnapshots: [UUID: ControlCenterConversation] = [:]
    var chatLogWriteTask: Task<Void, Never>?

    func configure(settingsRuntime: SettingsRuntime) {
        self.settingsRuntime = settingsRuntime
    }

    func dataDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ControlCenterHostError.blocked("Application Support is unavailable.")
        }
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", isDirectory: true)
            .appendingPathComponent("ControlCenter", isDirectory: true)
    }

    func localStore() throws -> ControlCenterStore {
        if let store { return store }
        let next = try ControlCenterStore(directory: dataDirectory())
        store = next
        return next
    }

    func refreshSnapshot() async throws {
        snapshot = try await localStore().snapshot()
    }

    func load() async {
        do {
            let store = try localStore()
            try await refreshSnapshot()
            if !hasLoadedConnection {
                connection = try await store.connection()
                hasLoadedConnection = true
                await restoreChatConversation()
            }
            await loadSettings()
        } catch { self.error = error.localizedDescription }
    }

    func savedFavorite(for target: ControlCenterTarget) -> ControlCenterTarget? {
        if let identity = target.sessionIdentity {
            return snapshot.favorites.first { $0.sessionIdentity == identity }
        }
        return snapshot.favorites.first { $0.id == target.id }
    }

    func toggleFavorite(_ target: ControlCenterTarget) async {
        guard !isRunning, !isSavingFavorites else { return }
        isSavingFavorites = true
        defer { isSavingFavorites = false }
        await mutate { store in
            if let saved = self.savedFavorite(for: target) {
                try await store.removeFavorite(saved.id)
            } else {
                try await store.saveFavorite(target)
            }
        }
    }

    func saveFavorite(_ target: ControlCenterTarget) async {
        guard !isSavingFavorites else { return }
        isSavingFavorites = true
        defer { isSavingFavorites = false }
        await mutate { _ = try await $0.saveFavorite(target) }
    }
    func deleteFavorite(_ id: UUID) async {
        guard !isSavingFavorites else { return }
        isSavingFavorites = true
        defer { isSavingFavorites = false }
        await mutate { try await $0.removeFavorite(id) }
    }
    func saveCollection(_ collection: ControlCenterCollection) async {
        await mutate { try await $0.saveCollection(collection) }
    }
    func deleteCollection(_ id: UUID) async {
        await mutate { try await $0.removeCollection(id) }
    }
    func savePreference(_ preference: ControlCenterPreference) async {
        await mutate { try await $0.savePreference(preference) }
    }
    func deletePreference(_ id: UUID) async {
        await mutate { try await $0.removePreference(id) }
    }
    func saveConnection() async {
        let value = connection
        await mutate { try await $0.saveConnection(value) }
    }

    func mutate(_ action: (ControlCenterStore) async throws -> Void) async {
        guard !isRunning else { error = "Finish or cancel the current operation first."; return }
        do {
            error = nil
            try await action(localStore())
            try await refreshSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func runOperation(title: String, body: @escaping @MainActor () async throws -> Void) async {
        guard !isRunning else { error = "An operation is already running."; return }
        uncertainSessionIDs.removeAll(keepingCapacity: true)
        directoryArchiveMutationBlocked = false
        riskConfirmationDeclined = false
        isRunning = true
        cancelled = false
        error = nil
        output = ""
        streamingText = ""
        pendingChatText = ""
        pendingChatEntries = []
        chatEntries = []
        operation = ControlCenterOperation(title: title)
        let task = Task { @MainActor in
            do {
                try await self.refreshSnapshot()
                try self.checkCancellation()
                try await body()
            } catch {
                let status: ControlCenterStep.Status = self.cancelled || error is CancellationError ? .cancelled : (error is ControlCenterHostError ? .blocked : .failed)
                self.operation?.steps.append(ControlCenterStep(
                    title: status == .cancelled ? "Cancelled" : "Operation failed",
                    status: status,
                    detail: status == .cancelled ? "Stopped remaining work. Completed actions were not rolled back." : error.localizedDescription
                ))
                if status != .cancelled { self.error = error.localizedDescription }
            }
            do {
                if self.activeChatTurnID == nil, let operation = self.operation { try await self.localStore().saveOperation(operation) }
                try await self.refreshSnapshot()
            } catch { self.error = error.localizedDescription }
            await self.finishChatTurn()
            self.isRunning = false
            self.activeTask = nil
        }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func record(_ step: ControlCenterStep) async throws {
        operation?.steps.append(step)
        if activeChatTurnID == nil, let operation { try await localStore().saveOperation(operation) }
        if activeChatTurnID != nil {
            appendChatLog("operation.receipt", payload: (try? toolJSON(step)) ?? .null)
        }
    }

    func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        activeTask?.cancel()
        resolveApproval(false)
    }

    func resetContext() {
        contextGeneration += 1
        lastContext = []
        if !isRunning { output = ""; streamingText = "" }
    }

    func loadModels() async {
        await runOperation(title: "List models") {
            self.models = try await ControlCenterModelClient(connection: self.connection).models()
            try await self.record(ControlCenterStep(title: "Models", status: .success, detail: "Loaded \(self.models.count) models."))
        }
    }
}
