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
    private(set) var actionError: CodexpressManagementError?

    @ObservationIgnored private let service: any CodexpressManagementServing
    @ObservationIgnored private let waitForRefresh: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var settings = CodexpressSettingsSnapshot()
    @ObservationIgnored private var refreshOperations: [String: String] = [:]
    @ObservationIgnored private var resetRequestIDs: [String: UUID] = [:]
    @ObservationIgnored private var requestsInFlight: Set<String> = []

    init(
        service: any CodexpressManagementServing,
        waitForRefresh: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.service = service
        self.waitForRefresh = waitForRefresh
    }

    /// Applies live preferences without losing uncertain or pending operation IDs.
    func applySettings(_ next: CodexpressSettingsSnapshot) {
        let cadenceChanged = settings.enabled != next.enabled
            || settings.pollIntervalSeconds != next.pollIntervalSeconds
        settings = next
        if cadenceChanged { restartObservation() }
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
        isUpdating = true
        defer { isUpdating = false }
        do {
            let next = try await service.status()
            try Task.checkCancellation()
            if snapshot != next { snapshot = next }
            connectionError = nil
        } catch is CancellationError {
            return
        } catch {
            connectionError = managementError(error)
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
        let action: CodexpressManagementAction = source.kind == "official"
            ? .refreshQuota(sourceID: source.id)
            : .refreshBalance(sourceID: source.id)
        await perform(action, sourceID: source.id, tracksRefresh: true)
    }

    func requestReset(_ sourceID: String) async {
        guard settings.enabled, settings.showActions,
              !activeSourceIDs.contains(sourceID), resetRequestIDs[sourceID] == nil,
              let source = snapshot?.sources.first(where: { $0.id == sourceID }),
              source.enabled, source.kind == "official" else { return }
        let id = UUID()
        // Keep the same ID even if POST delivery is unknown. Reconciliation is GET-only.
        resetRequestIDs[sourceID] = id
        resetRequests[sourceID] = CodexpressResetRequest(
            id: id.uuidString,
            sourceID: sourceID,
            status: "pending_confirmation"
        )
        requestsInFlight.insert(sourceID)
        activeSourceIDs.insert(sourceID)
        actionError = nil
        defer {
            requestsInFlight.remove(sourceID)
            if refreshOperations[sourceID] == nil { activeSourceIDs.remove(sourceID) }
        }
        do {
            _ = try await service.perform(.requestReset(sourceID: sourceID, requestID: id))
        } catch {
            let failure = managementError(error)
            actionError = failure
            // A definite local/HTTP rejection cannot have created a confirmation request.
            if failure.isDefiniteRejection {
                resetRequestIDs.removeValue(forKey: sourceID)
                resetRequests.removeValue(forKey: sourceID)
            }
        }
        await reconcileReset(sourceID: sourceID, id: id)
    }

    func dismissActionError() { actionError = nil }

    private func perform(
        _ action: CodexpressManagementAction,
        sourceID: String,
        tracksRefresh: Bool = false
    ) async {
        guard settings.enabled, settings.showActions, !activeSourceIDs.contains(sourceID),
              snapshot?.sources.contains(where: { $0.id == sourceID }) == true else { return }
        activeSourceIDs.insert(sourceID)
        requestsInFlight.insert(sourceID)
        actionError = nil
        defer {
            requestsInFlight.remove(sourceID)
            if refreshOperations[sourceID] == nil { activeSourceIDs.remove(sourceID) }
        }
        do {
            let operation = try await service.perform(action)
            if tracksRefresh, let id = operation.id, operation.status == "running" {
                refreshOperations[sourceID] = id
            }
        } catch {
            actionError = managementError(error)
        }
        await refreshLocal()
    }

    private func reconcileActions() async {
        for (sourceID, id) in refreshOperations {
            guard !Task.isCancelled else { return }
            do {
                let operation = try await service.operation(id: id)
                if operation.status == "completed" || operation.status == "failed" {
                    refreshOperations.removeValue(forKey: sourceID)
                    if !requestsInFlight.contains(sourceID) { activeSourceIDs.remove(sourceID) }
                    if operation.status == "failed" || operation.result?.sources.contains(where: { $0.status == "failed" }) == true {
                        actionError = .httpStatus(409)
                    }
                }
            } catch is CancellationError {
                return
            } catch let failure as CodexpressManagementError {
                if case .httpStatus(404) = failure {
                    refreshOperations.removeValue(forKey: sourceID)
                    if !requestsInFlight.contains(sourceID) { activeSourceIDs.remove(sourceID) }
                }
                actionError = failure
            } catch {
                actionError = managementError(error)
            }
        }
        for (sourceID, id) in resetRequestIDs {
            guard !Task.isCancelled else { return }
            await reconcileReset(sourceID: sourceID, id: id)
        }
    }

    private func reconcileReset(sourceID: String, id: UUID) async {
        guard resetRequestIDs[sourceID] == id else { return }
        do {
            let request = try await service.resetRequest(id: id)
            guard resetRequestIDs[sourceID] == id else { return }
            guard request.id.caseInsensitiveCompare(id.uuidString) == .orderedSame,
                  request.sourceID == sourceID else {
                actionError = .invalidResponse
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
            // A 404 after an uncertain POST is not permission to submit a new UUID.
            actionError = managementError(error)
        }
    }

    private func managementError(_ error: any Error) -> CodexpressManagementError {
        (error as? CodexpressManagementError) ?? .unavailable
    }
}
