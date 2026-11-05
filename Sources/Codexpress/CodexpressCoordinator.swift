import CmuxSettings
import Foundation
import Observation

/// Owns the visible Codexpress snapshot and non-replaying management actions.
@MainActor
@Observable
final class CodexpressCoordinator {
    private(set) var snapshot: CodexpressSnapshot?
    private(set) var connectionError: CodexpressManagementError?
    private(set) var isUpdating = false
    private(set) var activeSourceIDs: Set<String> = []
    private(set) var resetRequests: [String: CodexpressResetRequest] = [:]
    private var operationError: CodexpressManagementError?
    private var refreshErrors: [String: CodexpressManagementError] = [:]
    var actionError: CodexpressManagementError? {
        operationError ?? refreshErrors.min(by: { $0.key < $1.key })?.value
    }

    @ObservationIgnored private let service: any CodexpressManagementServing
    @ObservationIgnored private let waitForRefresh: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var connectionChangesTask: Task<Void, Never>?
    @ObservationIgnored private var settings = CodexpressSettingsSnapshot()
    @ObservationIgnored private var refreshOperations: [String: String] = [:]
    @ObservationIgnored private var refreshRetryTimes: [String: Double] = [:]
    @ObservationIgnored private var resetRequestIDs: [String: UUID] = [:]
    @ObservationIgnored private var requestsInFlight: Set<String> = []
    @ObservationIgnored private var connectionGeneration = UUID()
    private(set) var actionsBlockedAfterConnectionChange = false
    @ObservationIgnored private var uncertainSourceIDs: Set<String> = []

    /// Drops endpoint-specific state; uncertain old mutations remain blocked for this session.
    func connectionDidChange() {
        if !activeSourceIDs.isEmpty || !resetRequestIDs.isEmpty || !refreshOperations.isEmpty
            || operationError?.isDefiniteRejection == false {
            actionsBlockedAfterConnectionChange = true
        }
        connectionGeneration = UUID()
        snapshot = nil
        connectionError = nil
        isUpdating = false
        activeSourceIDs.removeAll()
        resetRequests.removeAll()
        refreshOperations.removeAll()
        refreshErrors.removeAll()
        refreshRetryTimes.removeAll()
        resetRequestIDs.removeAll()
        requestsInFlight.removeAll()
        uncertainSourceIDs.removeAll()
        operationError = actionsBlockedAfterConnectionChange ? .outcomeUnknown : nil
        restartObservation()
    }

    init(
        service: any CodexpressManagementServing,
        waitForRefresh: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.service = service
        self.waitForRefresh = waitForRefresh
    }

    deinit { connectionChangesTask?.cancel() }

    /// Retains one secret-change subscription shared by all sidebar instances.
    func startObservingConnectionChanges(secretStore: SecretFileStore, key: SecretFileKey) {
        guard connectionChangesTask == nil else { return }
        let changes = secretStore.values(for: key)
        connectionChangesTask = Task { [weak self] in
            var isInitialValue = true
            for await _ in changes {
                guard !Task.isCancelled else { return }
                if isInitialValue {
                    isInitialValue = false
                    continue
                }
                guard let self else { return }
                if settings.manualConnection { connectionDidChange() }
            }
        }
    }

    /// Preserves pending operations for display changes, but never across connections.
    func applySettings(_ next: CodexpressSettingsSnapshot) {
        let cadenceChanged = settings.enabled != next.enabled
            || settings.pollIntervalSeconds != next.pollIntervalSeconds
        let connectionChanged = settings.manualConnection != next.manualConnection
            || (next.manualConnection && settings.managementPort != next.managementPort)
        settings = next
        if connectionChanged {
            connectionDidChange()
        } else if cadenceChanged {
            restartObservation()
        }
    }

    /// Shares one local-status cadence across all visible sidebar instances.
    func observe() async {
        let id = UUID()
        let lease = AsyncStream<Void> { observers[id] = $0 }
        if observers.count == 1 { restartObservation() }
        defer {
            observers.removeValue(forKey: id)
            if observers.isEmpty { restartObservation() }
        }
        for await _ in lease {}
    }

    private func restartObservation() {
        let previous = observationTask
        previous?.cancel()
        // Await cancellation before starting another cadence, even if a service
        // call does not return immediately. Multiple sidebar leases never poll twice.
        observationTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, settings.enabled, !observers.isEmpty else { return }
            while !Task.isCancelled && settings.enabled && !observers.isEmpty {
                await refreshLocal()
                guard !Task.isCancelled, settings.enabled else { return }
                await reconcileActions()
                do { try await waitForRefresh(settings.pollIntervalSeconds) }
                catch { return }
            }
        }
    }

    func refreshLocal() async {
        guard settings.enabled, !Task.isCancelled, !isUpdating else { return }
        let generation = connectionGeneration
        isUpdating = true
        defer {
            if connectionGeneration == generation { isUpdating = false }
        }
        do {
            let next = try await service.status()
            try Task.checkCancellation()
            guard connectionGeneration == generation else { return }
            for source in next.sources where !source.hasRefreshFailure {
                if snapshot?.sources.first(where: { $0.id == source.id })?.hasRefreshFailure == true {
                    refreshErrors.removeValue(forKey: source.id)
                    refreshRetryTimes.removeValue(forKey: source.id)
                }
            }
            if snapshot != next { snapshot = next }
            connectionError = nil
        } catch is CancellationError {
            return
        } catch {
            guard connectionGeneration == generation else { return }
            let failure = managementError(error)
            if case .connectionChanged = failure { connectionDidChange() }
            connectionError = failure
        }
    }

    func takeOver(_ sourceID: String) async {
        await perform(.takeover(sourceID: sourceID), sourceID: sourceID)
    }

    func cancelTakeover() async {
        guard let route = snapshot?.manualRoute else { return }
        await perform(.cancelTakeover(id: route.id), sourceID: route.sourceID)
    }

    func recover(_ sourceID: String) async {
        await perform(.recover(sourceID: sourceID), sourceID: sourceID)
    }

    func refresh(_ source: CodexpressSnapshot.Source) async {
        guard let current = snapshot?.sources.first(where: { $0.id == source.id }) else { return }
        let now = Date().timeIntervalSince1970
        if let retryAt = current.refreshRetryAt, retryAt > now { return }
        if let retryAt = refreshRetryTimes[source.id], retryAt > now { return }
        let action: CodexpressManagementAction = current.kind == "official"
            ? .refreshQuota(sourceID: source.id)
            : .refreshBalance(sourceID: source.id)
        await perform(action, sourceID: source.id, tracksRefresh: true)
    }

    func requestReset(_ sourceID: String) async {
        guard settings.enabled, settings.showActions, !actionsBlockedAfterConnectionChange,
              !activeSourceIDs.contains(sourceID), resetRequestIDs[sourceID] == nil,
              let source = snapshot?.sources.first(where: { $0.id == sourceID }),
              source.enabled, source.kind == "official" else { return }
        let id = UUID()
        let generation = connectionGeneration
        // Keep the same ID even if POST delivery is unknown. Reconciliation is GET-only.
        resetRequestIDs[sourceID] = id
        resetRequests[sourceID] = CodexpressResetRequest(
            id: id.uuidString,
            sourceID: sourceID,
            status: "pending_confirmation"
        )
        requestsInFlight.insert(sourceID)
        activeSourceIDs.insert(sourceID)
        operationError = nil
        defer {
            if connectionGeneration == generation {
                requestsInFlight.remove(sourceID)
                if refreshOperations[sourceID] == nil { activeSourceIDs.remove(sourceID) }
            }
        }
        do {
            _ = try await service.perform(.requestReset(sourceID: sourceID, requestID: id))
            guard connectionGeneration == generation else { return }
        } catch {
            guard connectionGeneration == generation else { return }
            let failure = managementError(error)
            operationError = failure
            // A definite local/HTTP rejection cannot have created a confirmation request.
            if failure.isDefiniteRejection {
                resetRequestIDs.removeValue(forKey: sourceID)
                resetRequests.removeValue(forKey: sourceID)
            }
            if case .connectionChanged = failure {
                requestsInFlight.remove(sourceID)
                activeSourceIDs.remove(sourceID)
                connectionDidChange()
                return
            }
        }
        await reconcileReset(sourceID: sourceID, id: id)
    }

    func dismissActionError() {
        guard !actionsBlockedAfterConnectionChange else { return }
        if operationError != nil {
            operationError = nil
        } else if let sourceID = refreshErrors.keys.min() {
            refreshErrors.removeValue(forKey: sourceID)
        }
    }

    private func perform(
        _ action: CodexpressManagementAction,
        sourceID: String,
        tracksRefresh: Bool = false
    ) async {
        guard settings.enabled, settings.showActions, !actionsBlockedAfterConnectionChange,
              !activeSourceIDs.contains(sourceID),
              snapshot?.sources.contains(where: { $0.id == sourceID }) == true else { return }
        let generation = connectionGeneration
        activeSourceIDs.insert(sourceID)
        requestsInFlight.insert(sourceID)
        if !tracksRefresh { operationError = nil }
        defer {
            if connectionGeneration == generation {
                requestsInFlight.remove(sourceID)
                if refreshOperations[sourceID] == nil && !uncertainSourceIDs.contains(sourceID) {
                    activeSourceIDs.remove(sourceID)
                }
            }
        }
        do {
            let operation = try await service.perform(action)
            guard connectionGeneration == generation else { return }
            if tracksRefresh {
                if let id = operation.id, operation.status == "running" {
                    refreshOperations[sourceID] = id
                } else {
                    finishRefresh(operation, sourceID: sourceID)
                }
            }
        } catch {
            guard connectionGeneration == generation else { return }
            let failure = managementError(error)
            if case .outcomeUnknown = failure { uncertainSourceIDs.insert(sourceID) }
            if case .connectionChanged = failure {
                requestsInFlight.remove(sourceID)
                activeSourceIDs.remove(sourceID)
                connectionDidChange()
            }
            operationError = actionsBlockedAfterConnectionChange ? .outcomeUnknown : failure
        }
        await refreshLocal()
    }

    private func reconcileActions() async {
        let generation = connectionGeneration
        for (sourceID, id) in refreshOperations {
            guard !Task.isCancelled, connectionGeneration == generation else { return }
            do {
                let operation = try await service.operation(id: id)
                guard connectionGeneration == generation else { return }
                if operation.status == "completed" || operation.status == "failed" {
                    refreshOperations.removeValue(forKey: sourceID)
                    if !requestsInFlight.contains(sourceID) { activeSourceIDs.remove(sourceID) }
                    finishRefresh(operation, sourceID: sourceID)
                }
            } catch is CancellationError {
                return
            } catch let failure as CodexpressManagementError {
                guard connectionGeneration == generation else { return }
                if case .connectionChanged = failure {
                    connectionDidChange()
                    return
                }
                if case .httpStatus(404) = failure {
                    refreshOperations.removeValue(forKey: sourceID)
                    if !requestsInFlight.contains(sourceID) { activeSourceIDs.remove(sourceID) }
                }
                operationError = failure
            } catch {
                guard connectionGeneration == generation else { return }
                operationError = managementError(error)
            }
        }
        for (sourceID, id) in resetRequestIDs {
            guard !Task.isCancelled, connectionGeneration == generation else { return }
            await reconcileReset(sourceID: sourceID, id: id)
        }
    }

    private func finishRefresh(_ operation: CodexpressOperation, sourceID: String) {
        let result = operation.result?.sources.first(where: { $0.sourceID == sourceID })
        if operation.status == "failed" || result?.status == "failed" {
            if let retryAt = result?.nextRetryAt, retryAt.isFinite {
                refreshRetryTimes[sourceID] = retryAt
            }
            if result?.code == "source_changed" {
                operationError = .invalidConfiguration
            } else {
                refreshErrors[sourceID] = .refreshFailed(
                    sourceID: sourceID,
                    code: result?.code,
                    nextRetryAt: result?.nextRetryAt
                )
            }
        } else if operation.status == "completed", result?.status == "completed" {
            refreshErrors.removeValue(forKey: sourceID)
            refreshRetryTimes.removeValue(forKey: sourceID)
        }
    }

    private func reconcileReset(sourceID: String, id: UUID) async {
        guard resetRequestIDs[sourceID] == id else { return }
        let generation = connectionGeneration
        do {
            let request = try await service.resetRequest(id: id)
            guard connectionGeneration == generation, resetRequestIDs[sourceID] == id else { return }
            guard request.id.caseInsensitiveCompare(id.uuidString) == .orderedSame,
                  request.sourceID == sourceID else {
                operationError = .invalidResponse
                return
            }
            resetRequests[sourceID] = request
            if ["completed", "cancelled", "failed"].contains(request.status) {
                resetRequestIDs.removeValue(forKey: sourceID)
                if request.status == "completed" { await refreshLocal() }
            }
        } catch is CancellationError {
            return
        } catch {
            guard connectionGeneration == generation else { return }
            if case .connectionChanged = managementError(error) {
                connectionDidChange()
                return
            }
            // A 404 after an uncertain POST is not permission to submit a new UUID.
            operationError = managementError(error)
        }
    }

    private func managementError(_ error: any Error) -> CodexpressManagementError {
        (error as? CodexpressManagementError) ?? .unavailable
    }
}
