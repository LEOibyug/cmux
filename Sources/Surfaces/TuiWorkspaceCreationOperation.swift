import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

/// One request owns its receipt and native reservation until the graph adopts them.
@MainActor
final class TuiWorkspaceCreationOperation {
    /// Nil means a successfully read graph has no workspace to reuse; failures throw.
    typealias ResolveExistingWorkspace = @MainActor () async throws -> (
        workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource?, remoteView: SurfaceRemoteView?
    )?

    let id = UUID()
    let provider: any SurfaceProvider
    var host: TuiWorkspaceCreationHost?
    let allowsActionRetry: Bool
    var validateOperation: @MainActor () throws -> Void
    /// Discovery runs after local admission and repeats on retry until a receipt is retained.
    var resolveExistingWorkspace: ResolveExistingWorkspace?
    let terminalRequest = TuiTerminalCreationRequest()
    var receipt: SurfaceWorkspaceCreationReceipt?
    /// The exact daemon tab selected by an existing-workspace row, when the
    /// row represents a terminal with more than one remote view.
    var existingRemoteView: SurfaceRemoteView?
    /// The immutable row group admitted by an existing-workspace open. The
    /// catalog re-resolves it before materialization, so this is request
    /// ownership rather than a second presentation graph.
    var pendingWorkspaceGroup: SurfaceResourceGroup?
    var reservation: TuiTerminalPaneReservation?
    var openedProjections: [SurfaceProjection] = []
    var terminal: SurfaceResource?
    var terminalCursor: TuiCursor?
    var isComplete = false
    var isRunning = false
    var failure: Error?
    var retryTask: Task<Void, Never>?
    /// Remote resources created by this operation are cleaned up on cancellation.
    /// Failed live panes retain them for their explicit retry action.
    var ownsRemoteWorkspace = false
    var ownsRemoteTerminal = false
    var remoteCleanupStarted = false
    /// Existing-workspace opens must roll back their local admission on an
    /// attach/materialization error. New workspace creates retain a live pane
    /// for the established reconnect affordance.
    var isExistingWorkspaceOpen = false
    /// The host admitted this pane before provider lookup; do not restart its receipt attempt.
    var wasPreAdmitted = false

    init(
        provider: any SurfaceProvider,
        host: TuiWorkspaceCreationHost?,
        allowsActionRetry: Bool,
        validateOperation: @escaping @MainActor () throws -> Void
    ) {
        self.provider = provider
        self.host = host
        self.allowsActionRetry = allowsActionRetry
        self.validateOperation = validateOperation
    }

    var machine: SurfaceMachineID { provider.machine }

    func isConfirmed(in state: TuiState) -> Bool {
        guard let receipt, let terminal, state.workspaceIDs.contains(receipt.workspace.id),
              state.lookupIndex.terminal(id: terminal.id.key) != nil else { return false }
        if let cursor = terminalCursor ?? receipt.cursor {
            guard let accepted = state.cursor, accepted.generation == cursor.generation,
                  accepted.revision >= cursor.revision else { return false }
        }
        return containsStarter(in: state)
    }

    func containsStarter(in state: TuiState) -> Bool {
        guard let terminal, state.lookupIndex.terminal(id: terminal.id.key) != nil else { return false }
        guard let view = terminal.remoteViews?.first(where: { $0.workspace.id == receipt?.workspace.id }) else { return true }
        guard let tab = state.lookupIndex.tab(id: view.tabID),
              tab.contentKind == terminal.kind.rawValue, tab.contentID == terminal.id.key,
              let pane = state.lookupIndex.pane(id: tab.paneID),
              let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
        return screen.workspaceID == receipt?.workspace.id
    }

}
