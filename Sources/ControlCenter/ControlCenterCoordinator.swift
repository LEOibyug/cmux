import Combine
import CmuxControlCenter
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
    @Published var sessionSourceID = "omp" {
        didSet {
            if oldValue != sessionSourceID {
                sessionSearchGeneration += 1
                sessions = []
                sessionResultsSourceID = nil
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
    var sessionTargetIDs: [ControlCenterTarget.SessionIdentity: UUID] = [:]
    var sessionSearchGeneration = 0
    var openedTargets: [String: UUID] = [:]

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
        isRunning = true
        cancelled = false
        error = nil
        output = ""
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
                if let operation = self.operation { try await self.localStore().saveOperation(operation) }
                try await self.refreshSnapshot()
            } catch { self.error = error.localizedDescription }
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
        if let operation { try await localStore().saveOperation(operation) }
    }

    func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        activeTask?.cancel()
    }

    func resetContext() {
        contextGeneration += 1
        lastContext = []
        if !isRunning { output = "" }
    }

    func loadModels() async {
        await runOperation(title: "List models") {
            self.models = try await ControlCenterModelClient(connection: self.connection).models()
            try await self.record(ControlCenterStep(title: "Models", status: .success, detail: "Loaded \(self.models.count) models."))
        }
    }
}
