import AppKit
import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudWorkspaceDeleteOptimismTests {
    @Test func deletionIsVisibleBeforeProviderRefresh() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        provider.onRefresh = {
            #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.isEmpty == true)
            #expect(catalog.snapshot.resources.isEmpty)
            #expect(catalog.resources[provider.terminal.id] != nil, "Keep authoritative state for rollback")
        }
        let count = try await catalog.deleteTuiWorkspace(machine: provider.machine,
            workspaceID: provider.workspace.id, provider: provider).value
        #expect(count == 1)
        #expect(provider.closedTerminals == [provider.terminal.id])
        #expect(catalog.snapshot.resources.isEmpty)
    }
    @Test func admissionAndRepeatedCallsShareOneMutation() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let restoring = SurfaceProjection(resource: .init(machine: .local, kind: .terminal, key: "restoring"),
            workspaceID: UUID(), panelID: UUID())
        catalog.record(restoring)
        let first = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        #expect(catalog.snapshot.resources.isEmpty, "Removal is synchronous, before the task runs")
        #expect(catalog.snapshot.projections == [restoring], "An unrelated restoring pane must remain visible")
        #expect(catalog.snapshot.pendingWorkspaceDeletions?[provider.machine] == [provider.workspace.id])
        let second = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(provider.closedTerminals.count == 1 && provider.closedWorkspaces.count == 1)
        catalog.updateMachine(provider.info, from: provider)
        catalog.replaceResources([provider.terminal], on: provider.machine, from: provider)
        #expect(catalog.snapshot.resources.isEmpty, "A late provider refresh cannot resurrect the terminal")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.isEmpty == true)
        #expect(catalog.snapshot.pendingWorkspaceDeletions?.isEmpty == true)
    }

    @Test func failedDeleteRestoresSnapshotAndPreservesErrorForRetry() async throws {
        enum Failure: Error { case denied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let previous = catalog.snapshot
        provider.beforeTerminalClose = { _ in throw Failure.denied }
        let failed = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do { _ = try await failed.value; Issue.record("Expected backend failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot == previous)
        provider.beforeTerminalClose = { _ in }
        #expect(try await catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id).value == 1)
        #expect(catalog.snapshot.resources.isEmpty)
    }

    @Test func cancelledDeleteRollsBackBeforeDestruction() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let previous = catalog.snapshot
        let deletion = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        deletion.cancel()
        do { _ = try await deletion.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(catalog.snapshot == previous)
        #expect(provider.closedTerminals.isEmpty && provider.closedWorkspaces.isEmpty)
    }


    @Test func staleNavigationIsCancelledOnlyForDeletedWorkspace() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let deletion = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do {
            try catalog.checkTuiWorkspaceNavigation(machine: provider.machine, workspaceID: provider.workspace.id)
            Issue.record("Deleted workspace must reject navigation")
        } catch { #expect(error is CancellationError) }
        try catalog.checkTuiWorkspaceNavigation(machine: provider.machine, workspaceID: "unrelated")
        _ = try await deletion.value
    }

    @Test func concurrentDeletesAndPartialFailurePreserveUnrelatedState() async throws {
        enum Failure: Error { case denied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        let other = SurfaceRemoteWorkspace(id: "ws-other", name: "Keep me", index: 1, focused: false)
        var info = provider.info
        info.remoteWorkspaces?.append(other)
        catalog.updateMachine(info, from: provider)
        var secondTerminal = provider.terminal
        secondTerminal.id.key = "term-other"
        secondTerminal.remoteWorkspace = other
        catalog.replaceResources([provider.terminal, secondTerminal], on: provider.machine)
        provider.beforeTerminalClose = { id in
            if id.key == "term-other" { throw Failure.denied }
            catalog.remove(id, from: provider)
        }
        let first = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        let second = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(catalog.snapshot.resources.isEmpty)
        _ = try await first.value
        do { _ = try await second.value; Issue.record("Expected second deletion failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot.resources == [secondTerminal])
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces == [other])
        #expect(provider.closedWorkspaces == [provider.workspace.id])
        #expect(catalog.snapshot.machines.count == 1, "Never delete the Cloud VM")
    }

    @Test func confirmedTerminalCloseIsNotResurrectedWhenWorkspaceCloseFails() async throws {
        enum Failure: Error { case workspaceDenied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        provider.beforeTerminalClose = { catalog.remove($0, from: provider) }
        provider.beforeClose = { throw Failure.workspaceDenied }
        let deletion = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do { _ = try await deletion.value; Issue.record("Expected workspace failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot.resources.isEmpty, "Rollback cannot recreate a killed process")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces == [provider.workspace])
        #expect(catalog.snapshot.pendingWorkspaceDeletions == nil)
    }


    @Test("A provider replaced during refresh cannot receive destructive calls")
    func providerReplacementCancelsDelete() async throws {
        let catalog = SurfaceCatalog()
        let old = CloudWorkspaceDeleteTestProvider()
        let replacement = CloudWorkspaceDeleteTestProvider()
        catalog.register(old)
        catalog.replaceResources([old.terminal], on: old.machine)
        old.onRefresh = { catalog.register(replacement) }
        let task = catalog.deleteTuiWorkspace(machine: old.machine, workspaceID: old.workspace.id)
        do { _ = try await task.value; Issue.record("Retired provider must not delete") }
        catch { #expect(error is CancellationError) }
        #expect(old.closedTerminals.isEmpty && old.closedWorkspaces.isEmpty)
        #expect(replacement.closedTerminals.isEmpty && replacement.closedWorkspaces.isEmpty)
        #expect(!catalog.isTuiWorkspaceDeletionHidden(machine: old.machine, workspaceID: old.workspace.id))
    }

    @Test("Concurrent workspaces sharing a terminal close its process once")
    func sharedTerminalClosesOnce() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        let other = SurfaceRemoteWorkspace(id: "other", name: "Other", index: 1, focused: false)
        var terminal = provider.terminal
        terminal.remoteViews = [SurfaceRemoteView(tabID: "first", workspace: provider.workspace),
                                SurfaceRemoteView(tabID: "second", workspace: other)]
        catalog.replaceResources([terminal], on: provider.machine)
        let first = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        let second = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(provider.closedTerminals == [terminal.id])
        #expect(Set(provider.closedWorkspaces) == [provider.workspace.id, other.id])
        let repeated = catalog.deleteTuiWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(try await repeated.value == 1)
        #expect(provider.closedWorkspaces.count == 2)
    }

}
