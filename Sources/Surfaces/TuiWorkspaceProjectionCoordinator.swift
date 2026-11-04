import CmuxRemoteSession
import CmuxTui
import CmuxSurfaceCatalogModel
import Foundation

/// Materializes the accepted Cloud graph into bound native workspaces. The graph
/// stays in SurfaceCatalog; this owner holds only cancellable work and local
/// mutation scopes, so snapshot, event and reconnect paths cannot maintain copies.
@MainActor
final class TuiWorkspaceProjectionCoordinator {
    var environment: TuiWorkspaceProjectionEnvironment
    private var tasks: [SurfaceMachineID: TuiWorkspaceProjectionTask] = [:]
    private var requested: Set<SurfaceMachineID> = []
    private var localMutations: [SurfaceMachineID: Set<UUID>] = [:]
    private(set) var failures: [UUID: String] = [:]

    init() {
        self.environment = TuiWorkspaceProjectionEnvironment()
    }

    init(environment: TuiWorkspaceProjectionEnvironment) {
        self.environment = environment
    }

    /// Admission is synchronous, before create/project can yield to a graph event.
    func beginLocalMutation(on machine: SurfaceMachineID) -> UUID {
        let token = UUID()
        localMutations[machine, default: []].insert(token)
        return token
    }

    func endLocalMutation(_ token: UUID, on machine: SurfaceMachineID, catalog: SurfaceCatalog) {
        localMutations[machine]?.remove(token)
        if localMutations[machine]?.isEmpty == true { localMutations[machine] = nil }
        if requested.contains(machine) { request(machine: machine, catalog: catalog) }
    }

    func request(machine: SurfaceMachineID, catalog: SurfaceCatalog) {
        guard !machine.isLocal else { return }
        requested.insert(machine)
        guard tasks[machine] == nil, localMutations[machine] == nil else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self, weak catalog] in
            guard let self else { return }
            defer { if self.tasks[machine]?.id == id { self.tasks[machine] = nil } }
            guard let catalog else { return }
            var budget = TuiWorkspaceReconcileBudget()
            while self.requested.remove(machine) != nil {
                guard !Task.isCancelled, self.localMutations[machine] == nil else { return }
                await catalog.tuiPlacementCoordinator.waitForPendingMutations()
                guard !Task.isCancelled,
                      self.localMutations[machine] == nil,
                      let state = catalog.tuiStates[machine],
                      catalog.tuiStateObservations[machine]?.freshness == .current,
                      catalog.tuiPlacementCoordinator.allowsNativeReconciliation(state) else { return }
                let progress = TuiWorkspaceReconcileBudget.Mark(
                    state: state,
                    projectionVersion: catalog.projectionVersions[machine, default: 0],
                    bindings: self.environment.bindings().filter { $0.value.machineID == machine.rawValue }
                )
                guard budget.admit(progress) else {
                    self.reportNonConvergence(machine: machine, state: state, budget: budget)
                    return
                }
                await self.reconcile(state: state, catalog: catalog)
            }
        }
        tasks[machine] = TuiWorkspaceProjectionTask(id: id, task: task)
    }

    /// Daemon generation last reported per machine. A persistent re-requester
    /// would otherwise report once for every graph revision.
    private var reportedNonConvergence: [SurfaceMachineID: String] = [:]
    /// The most recent non-empty plan per machine, so a non-convergence report
    /// names what the passes kept trying to add and retire.
    private var lastPlanShape: [SurfaceMachineID: TuiWorkspaceProjectionPlanShape] = [:]

    /// Reports non-convergence once per daemon generation, so a trigger outside
    /// this loop that keeps restarting it cannot flood crash reporting.
    private func reportNonConvergence(machine: SurfaceMachineID, state: TuiState, budget: TuiWorkspaceReconcileBudget) {
#if DEBUG
        cmuxDebugLog("tuiWorkspace.projection.nonConvergent machine=\(machine.rawValue) passes=\(budget.passes) idle=\(budget.idlePasses)")
#endif
        let generation = state.cursor?.generation ?? ""
        guard reportedNonConvergence[machine] != generation else { return }
        reportedNonConvergence[machine] = generation
#if DEBUG
        cmuxDebugLog("tuiWorkspace.projection.nonConvergent generation=\(generation) revision=\(state.cursor?.revision ?? 0)")
#endif
    }

    /// A bound mirror may not recreate a view that the accepted graph removed.
    /// Unbound viewers retain their existing attachment-repair behavior.
    func retainsProjection(_ projection: SurfaceProjection, in state: TuiState) -> Bool {
        guard let binding = environment.bindings()[projection.workspaceID], binding.machineID == state.machine.rawValue,
              let workspaceID = binding.remoteWorkspaceID else { return true }
        let tabs = state.lookupIndex.tabs(contentKind: projection.resource.kind.rawValue, contentID: projection.resource.key)
        return tabs.contains { tab in
            guard projection.remoteTabID == nil || projection.remoteTabID == tab.id,
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
            return screen.workspaceID == workspaceID
        }
    }


    func cancel(machine: SurfaceMachineID) {
        tasks.removeValue(forKey: machine)?.task.cancel()
        requested.remove(machine)
        localMutations[machine] = nil
        reportedNonConvergence[machine] = nil
        lastPlanShape[machine] = nil
        let bindings = environment.bindings()
        failures = failures.filter { bindings[$0.key]?.machineID != machine.rawValue }
    }

    func waitForIdle() async {
        for entry in Array(tasks.values) { await entry.task.value }
    }

    private func isCurrent(_ state: TuiState, catalog: SurfaceCatalog) -> Bool {
        !Task.isCancelled && localMutations[state.machine] == nil && catalog.tuiStates[state.machine] == state
            && catalog.tuiPlacementCoordinator.allowsNativeReconciliation(state)
    }

    private func reconcile(state: TuiState, catalog: SurfaceCatalog) async {
        let machine = state.machine
        let completeness = TuiGraphCompleteness(state: state, resources: catalog.snapshot.resources(on: machine))
        for (workspaceID, binding) in environment.bindings() where binding.machineID == machine.rawValue {
            guard let remoteID = binding.remoteWorkspaceID else { continue }
            if catalog.tuiWorkspaceCreationCoordinator.isPending(localWorkspaceID: workspaceID) { continue }
            // A delete owns this workspace's visible lifecycle. Do not let a
            // late projection refresh recreate its panes while the backend
            // request is pending; a committed delete will reconcile them once.
            if catalog.isTuiWorkspaceDeletionPending(machine: machine, workspaceID: remoteID) {
                continue
            }
            guard isCurrent(state, catalog: catalog) else {
                if !Task.isCancelled { requested.insert(machine) }
                return
            }
            // A move is a cross-workspace mutation. Do not let a complete source
            // workspace retire the projection while the destination inventory is
            // still incomplete and cannot reconcile the same tab yet.
            guard completeness.isComplete() else {
                continue
            }
            let group = try? catalog.remoteWorkspaceGroup(machine: machine, workspaceID: remoteID)
            let desired = (group?.placements ?? []).filter {
                !catalog.tuiPlacementCoordinator.isPendingClose($0, on: machine, workspaceID: remoteID)
            }
            let existing = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
            let plan = TuiWorkspaceProjectionPlan(
                desired: desired, existing: Array(existing),
                protectedPanelIDs: environment.pendingTuiBrowserPanelIDs(workspaceID)
            )
            if !plan.missing.isEmpty || !plan.obsolete.isEmpty {
                lastPlanShape[machine] = TuiWorkspaceProjectionPlanShape(plan)
            }
            // `project` may satisfy a missing placement by rewriting an obsolete
            // pane's coordinates. That pane now shows the placement; closing it
            // would make the next pass rebuild it, forever. A pane reused with
            // its old coordinates still does not show it and is still retired.
            var projectedPanels = Set<UUID>()
            do {
                for placement in plan.missing {
                    guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                        if !Task.isCancelled { requested.insert(machine) }
                        return
                    }
                    let view = try catalog.remoteView(
                        for: placement,
                        fallbackWorkspaceID: remoteID
                    )
                    let (projection, _) = try await catalog.project(placement.resource, into: .workspace(id: workspaceID, placement: .tab),
                                                  focus: false, reuseExisting: true, reuseInWorkspace: workspaceID, remoteView: view)
                    if projection.resource == placement.resource,
                       projection.remoteWorkspaceID == placement.remoteWorkspaceID,
                       projection.remoteTabID == placement.remoteTabID {
                        projectedPanels.insert(projection.panelID)
                    }
                }
                guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                    if !Task.isCancelled { requested.insert(machine) }
                    return
                }
                for projection in plan.obsolete where !projectedPanels.contains(projection.panelID) {
#if DEBUG
                    cmuxDebugLog("tuiWorkspace.projection.obsolete workspace=\(workspaceID) panel=\(projection.panelID) resource=\(projection.resource.rawValue) remoteWorkspace=\(projection.remoteWorkspaceID ?? "nil") tab=\(projection.remoteTabID ?? "nil") desired=\(desired.count)")
#endif
                    environment.close(projection)
                    catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                }
                let daemonDesired = desired.filter { $0.remoteTabID != nil }
                if let layout = catalog.tuiWorkspaceLayout(machine: machine, workspaceID: remoteID), !daemonDesired.isEmpty,
                   Set(daemonDesired).isSubset(of: Set(layout.placements)) {
                    let live = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
                    environment.applyLayout(workspaceID, layout, Array(live))
                }
                failures[workspaceID] = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failures[workspaceID] = RemoteMachineLink.errorText(error)
            }
        }
        let live = Set(environment.bindings().keys)
        failures = failures.filter { live.contains($0.key) }
    }
}

/// Privacy-safe summary of one reconcile plan: counts and the kinds of
/// placement each side holds, never resource, tab or workspace identifiers.
struct TuiWorkspaceProjectionPlanShape: Equatable {
    let missing: [String]
    let obsolete: [String]

    init(_ plan: TuiWorkspaceProjectionPlan) {
        missing = plan.missing.map { Self.kind($0.resource.kind, tab: $0.remoteTabID, workspace: $0.remoteWorkspaceID) }
        obsolete = plan.obsolete.map { Self.kind($0.resource.kind, tab: $0.remoteTabID, workspace: $0.remoteWorkspaceID) }
    }

    private static func kind(_ kind: SurfaceResourceKind, tab: String?, workspace: String?) -> String {
        "\(kind.rawValue):\(tab == nil ? "untabbed" : "tab"):\(workspace == nil ? "unplaced" : "placed")"
    }

}

/// Bounds reconciliation of one accepted graph. A pass that changes nothing
/// (same graph, projections and bindings as the pass before) cannot make the
/// next one different, so a few in a row mean a consumer is requesting passes
/// without progress. The hard ceiling also stops a loop that rewrites the same
/// projections every pass, which looks like progress.
struct TuiWorkspaceReconcileBudget {
    struct Mark: Equatable {
        let state: TuiState
        let projectionVersion: UInt64
        let bindings: [UUID: RemoteWorkspaceBinding]
    }

    static let maxIdlePasses = 3
    static let maxPassesPerState = 64

    private var last: Mark?
    private(set) var passes = 0
    private(set) var idlePasses = 0

    /// Records the catalog before a pass; false means stop reconciling this graph.
    mutating func admit(_ mark: Mark) -> Bool {
        if last?.state != mark.state { passes = 0; idlePasses = 0 }
        idlePasses = last == mark ? idlePasses + 1 : 0
        passes += 1
        last = mark
        return idlePasses < Self.maxIdlePasses && passes <= Self.maxPassesPerState
    }
}

