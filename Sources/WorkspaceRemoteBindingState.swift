import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// Owns SSH binding observation and asynchronous surface metadata projections.
@MainActor
@Observable
final class WorkspaceRemoteBindingState {
    var binding: RemoteWorkspaceBinding? {
        didSet {
            guard oldValue != binding else { return }
            bindingDidChange()
        }
    }
    private(set) var revision: UInt64 = 0
    private(set) var projectedResources: [UUID: SurfaceResourceID] = [:]
    private(set) var machineNames: [String: String] = [:]
    /// Lifecycle of each projected panel's catalog terminal; a panel is absent until its row exists.
    private(set) var terminalLifecycles: [UUID: SurfaceLifecycle] = [:]

    /// An immutable projection of catalog ownership, names and terminal readiness, delivered above the sidebar list.
    func updateCatalogMetadata(
        resources: [UUID: SurfaceResourceID],
        machineNames: [String: String],
        terminalLifecycles: [UUID: SurfaceLifecycle] = [:]
    ) {
        guard projectedResources != resources || self.machineNames != machineNames
            || self.terminalLifecycles != terminalLifecycles else { return }
        projectedResources = resources
        self.machineNames = machineNames
        self.terminalLifecycles = terminalLifecycles
        bindingDidChange()
    }
    @ObservationIgnored
    private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    /// Replays the current revision to every subscriber, then coalesces unread changes.
    func changes() -> AsyncStream<UInt64> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(revision)
            // AsyncStream termination is a nonisolated callback boundary.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    /// Notifies async consumers after the authoritative binding has changed.
    private func bindingDidChange() {
        revision &+= 1
        var terminatedIDs: [UUID] = []
        for (id, continuation) in observers {
            if case .terminated = continuation.yield(revision) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            observers[id] = nil
        }
    }
}
