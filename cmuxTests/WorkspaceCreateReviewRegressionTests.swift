import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateReviewRegressionTests {
    @Test("worktree creation result preserves filesystem identity")
    func worktreeCreationResultPreservesFilesystemIdentity() {
        let result = CmuxExtensionWorktreeCreationResult(
            projectRootPath: "/tmp/project",
            worktreePath: "/tmp/project/.cmux/worktrees/created",
            branchName: "cmux-sidebar-created",
            workspaceTitle: "cmux-sidebar-created",
            createdHead: String(repeating: "0", count: 40),
            generatedArtifactRelativePath: "cmux-sample-dev/index.html",
            generatedArtifactContents: Data(),
            worktreeDeviceID: 17,
            worktreeFileID: 29,
            setupCommand: ""
        )

        #expect(result.worktreeDeviceID == 17)
        #expect(result.worktreeFileID == 29)
    }

    

    

    

    

    

    

    private static func errorCode(_ result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }
}

@MainActor
private final class RejectingWorkspaceCreationTabManager: TabManager {
    var rejectsWorkspaceCreation = false

    override func addWorkspaceIfActive(
        id: UUID?,
        title: String?,
        titleSource: Workspace.CustomTitleSource,
        workingDirectory overrideWorkingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        initialTerminalCommand: String?,
        initialTerminalIsRemote: Bool,
        initialTerminalInput: String?,
        initialTerminalStartupRestoreAgent: SessionRestorableAgentSnapshot?,
        initialTerminalEnvironment: [String: String],
        initialBrowserURL: URL?,
        initialBrowserOmnibarVisible: Bool,
        initialBrowserTransparentBackground: Bool,
        workspaceEnvironment: [String: String],
        inheritWorkingDirectory: Bool,
        select: Bool,
        eagerLoadTerminal: Bool,
        initialTerminalStartsOnFirstVisit: Bool,
        placementOverride: WorkspacePlacement?,
        autoWelcomeIfNeeded: Bool,
        autoRefreshMetadata: Bool,
        normalizeWorkspaceGroupsAfterInsert: Bool,
        applyCreationTitleAsCustomTitle: Bool,
        allowTextBoxFocusDefault: Bool
    ) -> Workspace? {
        guard rejectsWorkspaceCreation else {
            return super.addWorkspaceIfActive(
                id: id,
                title: title,
                titleSource: titleSource,
                workingDirectory: overrideWorkingDirectory,
                initialSurface: initialSurface,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalIsRemote: initialTerminalIsRemote,
                initialTerminalInput: initialTerminalInput,
                initialTerminalStartupRestoreAgent: initialTerminalStartupRestoreAgent,
                initialTerminalEnvironment: initialTerminalEnvironment,
                initialBrowserURL: initialBrowserURL,
                initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                initialBrowserTransparentBackground: initialBrowserTransparentBackground,
                workspaceEnvironment: workspaceEnvironment,
                inheritWorkingDirectory: inheritWorkingDirectory,
                select: select,
                eagerLoadTerminal: eagerLoadTerminal,
                initialTerminalStartsOnFirstVisit: initialTerminalStartsOnFirstVisit,
                placementOverride: placementOverride,
                autoWelcomeIfNeeded: autoWelcomeIfNeeded,
                autoRefreshMetadata: autoRefreshMetadata,
                normalizeWorkspaceGroupsAfterInsert: normalizeWorkspaceGroupsAfterInsert,
                applyCreationTitleAsCustomTitle: applyCreationTitleAsCustomTitle,
                allowTextBoxFocusDefault: allowTextBoxFocusDefault
            )
        }
        return nil
    }
}



private actor ControlledReviewDeadlines {
    private var count = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspendUntilFired() async {
        count += 1
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func fireAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
