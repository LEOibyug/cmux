import CmuxFoundation
import Foundation
import os

/// Coalesced PTY-output wakeups for local screen-text waits. No byte replay or network transport.
final class TerminalOutputUpdateHub: @unchecked Sendable {
    nonisolated static let shared = TerminalOutputUpdateHub()

    private struct State {
        var subscriptions: [UUID: [UUID: AsyncStream<Void>.Continuation]] = [:]
        var count = 0
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated private let hasDemand = AtomicBooleanGate(false)

    nonisolated private init() {}

    nonisolated func outputUpdates(surfaceID: UUID) -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.withLock { value in
                value.subscriptions[surfaceID, default: [:]][id] = continuation
                value.count += 1
                hasDemand.storeRelease(true)
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeSubscription(id: id, surfaceID: surfaceID)
            }
        }
    }

    /// Called on the PTY read thread. The idle path does not lock, allocate, or copy bytes.
    nonisolated func signalOutput(surfaceID: UUID) {
        guard hasDemand.loadAcquire() else { return }
        // Retain the immutable dictionary storage under the lock, then yield outside
        // it: stream termination may synchronously remove a subscription.
        let subscriptions = state.withLock { $0.subscriptions[surfaceID] }
        guard let subscriptions else { return }
        for continuation in subscriptions.values {
            continuation.yield(())
        }
    }

    nonisolated func dropSurface(surfaceID: UUID) {
        let subscriptions = state.withLock { value in
            let removed = value.subscriptions.removeValue(forKey: surfaceID)
            value.count -= removed?.count ?? 0
            hasDemand.storeRelease(value.count > 0)
            return removed
        }
        guard let subscriptions else { return }
        for continuation in subscriptions.values {
            continuation.finish()
        }
    }

    nonisolated private func removeSubscription(id: UUID, surfaceID: UUID) {
        state.withLock { value in
            guard value.subscriptions[surfaceID]?.removeValue(forKey: id) != nil else { return }
            if value.subscriptions[surfaceID]?.isEmpty == true {
                value.subscriptions.removeValue(forKey: surfaceID)
            }
            value.count -= 1
            hasDemand.storeRelease(value.count > 0)
        }
    }
}
