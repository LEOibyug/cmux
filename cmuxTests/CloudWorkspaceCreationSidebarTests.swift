import CmuxRemoteSession
import AppKit
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TuiWorkspaceCreationSidebarTests {
    @Test("An existing Cloud workspace row admits one local workspace before attach and reuses it on repeat")
    func existingWorkspaceRowOpensOptimisticallyAndIsIdempotent() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.manager.window = nil
            let workspace = SurfaceRemoteWorkspace(id: "ws_existing", name: "Existing", index: 0, focused: true)
            fixture.provider.createdWorkspaces = [workspace]
            fixture.provider.info.remoteWorkspaces = [workspace]
            fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
            let terminal = fixture.provider.terminal(in: workspace)
            fixture.catalog.upsert(terminal, from: fixture.provider)
            try fixture.provider.publish(revision: 10)

            let attachStarted = RemoteLinkFirstValue<Bool>()
            let releaseAttach = RemoteLinkFirstValue<Bool>()
            fixture.provider.beforeMaterialize = { _, _ in
                attachStarted.resolve(true)
                _ = await releaseAttach.result
            }
            let group = try fixture.catalog.remoteWorkspaceGroup(machine: fixture.provider.machine, workspaceID: workspace.id)
            let opening = Task { @MainActor in
                try await fixture.catalog.tuiWorkspaceCreationCoordinator.openExistingWorkspace(
                    provider: fixture.provider, workspace: workspace, group: group,
                    focus: true, host: TuiWorkspaceCreationHost(manager: fixture.manager)
                )
            }
            #expect(await attachStarted.result == true)

            let admitted = try #require(fixture.manager.tabs.first { $0.id != fixture.originalWorkspaceID })
            #expect(fixture.manager.tabs.count == 2)
            // The admitted workspace stays out of view until its remote layout
            // is applied (#16690), so the starter pane never paints first.
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations?[fixture.provider.machine]?[workspace.id] == admitted.id)
            #expect(fixture.catalog.snapshot.machines.first { $0.id == fixture.provider.machine }?.remoteWorkspaces?.contains { $0.id == workspace.id } == true)

            // A second activation while the attach is suspended is navigation
            // to the admitted local identity, never another local workspace.
            let repeated = try await fixture.catalog.tuiWorkspaceCreationCoordinator.openExistingWorkspace(
                provider: fixture.provider, workspace: workspace, group: group,
                focus: true, host: TuiWorkspaceCreationHost(manager: fixture.manager)
            )
            #expect(repeated.workspaceID == admitted.id)
            #expect(fixture.manager.tabs.count == 2)
            #expect(fixture.manager.selectedTabId == admitted.id)

            releaseAttach.resolve(true)
            #expect(try await opening.value.workspaceID == admitted.id)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.filter { $0.workspaceID == admitted.id }.count == 1)
        }
    }


    @Test("A failed existing Cloud workspace open rolls back and preserves the previous selection")
    func existingWorkspaceOpenFailureRollsBackSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.manager.window = fixture.window
            fixture.window.makeKeyAndOrderFront(nil)
            let workspace = SurfaceRemoteWorkspace(id: "ws_failure", name: "Failure", index: 0, focused: true)
            let other = try #require(fixture.manager.addWorkspaceIfActive(title: "Other", select: false))
            fixture.provider.createdWorkspaces = [workspace]
            fixture.provider.info.remoteWorkspaces = [workspace]
            fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
            fixture.catalog.upsert(fixture.provider.terminal(in: workspace), from: fixture.provider)
            try fixture.provider.publish(revision: 10)
            fixture.provider.beforeMaterialize = { _, _ in throw TuiTransportError.placementMismatch }

            let group = try fixture.catalog.remoteWorkspaceGroup(machine: fixture.provider.machine, workspaceID: workspace.id)
            await #expect(throws: TuiTransportError.placementMismatch) {
                try await fixture.catalog.tuiWorkspaceCreationCoordinator.openExistingWorkspace(
                    provider: fixture.provider, workspace: workspace, group: group,
                    focus: true, host: TuiWorkspaceCreationHost(manager: fixture.manager)
                )
            }
            #expect(fixture.manager.tabs.map(\.id) == [fixture.originalWorkspaceID, other.id])
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.isEmpty)
        }
    }

    @Test("A canceled existing workspace open cannot be resurrected by a late attach callback")
    func existingWorkspaceOpenCancellationFencesLateCallback() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.manager.window = fixture.window
            fixture.window.makeKeyAndOrderFront(nil)
            let workspace = SurfaceRemoteWorkspace(id: "ws_cancel", name: "Cancel", index: 0, focused: true)
            fixture.provider.createdWorkspaces = [workspace]
            fixture.provider.info.remoteWorkspaces = [workspace]
            fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
            fixture.catalog.upsert(fixture.provider.terminal(in: workspace), from: fixture.provider)
            try fixture.provider.publish(revision: 10)
            let attachStarted = RemoteLinkFirstValue<Bool>()
            let releaseAttach = RemoteLinkFirstValue<Bool>()
            fixture.provider.beforeMaterialize = { _, _ in
                attachStarted.resolve(true)
                _ = await releaseAttach.result
            }
            let group = try fixture.catalog.remoteWorkspaceGroup(machine: fixture.provider.machine, workspaceID: workspace.id)
            let opening = Task { @MainActor in
                try await fixture.catalog.tuiWorkspaceCreationCoordinator.openExistingWorkspace(
                    provider: fixture.provider, workspace: workspace, group: group,
                    focus: true, host: TuiWorkspaceCreationHost(manager: fixture.manager)
                )
            }
            #expect(await attachStarted.result == true)
            fixture.catalog.tuiWorkspaceCreationCoordinator.cancelAll()
            releaseAttach.resolve(true)
            await #expect(throws: CancellationError.self) { try await opening.value }
            #expect(fixture.manager.tabs.map(\.id) == [fixture.originalWorkspaceID])
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.isEmpty)
        }
    }

    @Test("Replacing a reservation preserves the committed remote workspace", arguments: [false, true])
    func successfulCreationDoesNotCancelWhenTheProviderReplacesItsPane(adoptsReservation: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Native pane teardown reports through the live catalog. A private
            // fixture catalog would miss the cancellation that deleted the Mac workspace.
            let fixture = try TuiWorkspaceCreationSidebarFixture(useSharedCatalog: true)
            defer { fixture.close() }
            fixture.provider.adoptsReservation = adoptsReservation
            let unexpectedClose = XCTestExpectation(description: "Successful creation must preserve remote resources")
            unexpectedClose.isInverted = true
            fixture.provider.onRemoteClose = { unexpectedClose.fulfill() }
            var operation: TuiWorkspaceCreationOperation?
            var reservedPanelID: UUID?
            fixture.provider.beforeMaterialize = { _, reservation in
                reservedPanelID = try #require(reservation).panelID
                operation = try #require(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.values.first {
                    $0.machine == fixture.provider.machine
                })
            }
            let result = try await fixture.create(
                
                name: nil, focus: false
            )
            let opened = try #require(result.opened)
            let workspace = try #require(fixture.manager.workspacesById[opened.workspaceID])
            let completed = try #require(operation)
            // Cleanup is scheduled asynchronously by native pane teardown.
            // Observe that negative event explicitly rather than sampling before it runs.
            let closeResult = await XCTWaiter.fulfillment(of: [unexpectedClose], timeout: 0.2)
            #expect(closeResult == .completed)
            #expect(completed.isComplete)
            #expect(!completed.remoteCleanupStarted)
            #expect(fixture.provider.closedWorkspaceIDs.isEmpty)
            #expect(fixture.provider.closedTerminalIDs.isEmpty)
            #expect(workspace.panels.count == 1)
            #expect((opened.projections.first?.panelID == reservedPanelID) == adoptsReservation)
        }
    }

    @Test("Both workspace sidebars share the create receipt before daemon refresh", arguments: [false, true])
    func receiptAppearsBeforeRefresh(focus: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let originalIDs = Set(fixture.manager.tabs.map(\.id))
            var pendingID: UUID?
            fixture.provider.beforeCreate = {
                let created = fixture.manager.tabs.filter { !originalIDs.contains($0.id) }
                #expect(created.count == 1, "The local Cloud pane must be admitted before remote creation returns")
            }
            fixture.provider.beforeRefresh = {
                let created = fixture.manager.tabs.filter { !originalIDs.contains($0.id) }
                #expect(created.count == 1, "The left navigator must contain the new workspace before refresh returns")
                pendingID = created.first?.id
                let remote = try #require(fixture.provider.createdWorkspaces.first)
                #expect(fixture.catalog.snapshot.pendingWorkspaceCreations?[fixture.provider.machine]?[remote.id] == pendingID)
                // Completion must not select over navigation performed while connecting.
                fixture.manager.selectedTabId = fixture.originalWorkspaceID
            }
            let result = try await fixture.create(
                
                name: nil, focus: focus
            )
            let opened = try #require(result.opened)
            #expect(opened.workspaceID == pendingID)
            #expect(fixture.manager.tabs.filter { !originalIDs.contains($0.id) }.count == 1)
            #expect(fixture.workspaces.count == 1)
            #expect(fixture.catalog.projections.filter { $0.workspaceID == opened.workspaceID }.count == 1)
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.provider.terminalCreates == 0, "A starter receipt must not spawn another terminal")
        }
    }

    @Test("Receipt, older snapshot, and accepted graph retain one native terminal and its first input")
    func snapshotsConvergeWithoutReplacingTheReservation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            var pendingID: UUID?
            var pendingPanel: TerminalPanel?
            var relay: TuiOptimisticInputRelay?
            fixture.provider.beforeMaterialize = { _, reservation in
                let reservation = try #require(reservation)
                let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                pendingID = workspace.id
                pendingPanel = try #require(workspace.terminalPanel(for: reservation.panelID))
                relay = reservation.inputRelay
                reservation.inputRelay.send(.bytes(Data("echo first command\n".utf8)))
                #expect(workspace.panels.count == 1)
                #expect(workspace.remoteWorkspaceBinding?.remoteWorkspaceID == fixture.provider.createdWorkspaces.first?.id)
                #expect(fixture.provider.refreshes == 0, "Current daemons must not refresh before publishing the receipt")
                try fixture.provider.publish(revision: 9, includesWorkspaces: false)
                await fixture.catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
                #expect(fixture.workspaces.count == 1)
                #expect(workspace.remoteWorkspaceBinding != nil, "A pre-receipt snapshot cannot clear the new binding")
                #expect(workspace.panels.count == 1)
                try fixture.provider.publish(revision: 10)
                await fixture.catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
                #expect(workspace.panels.count == 1, "An early event must not materialize a competing pane")
                fixture.manager.selectedTabId = fixture.originalWorkspaceID
            }
            let result = try await fixture.create(
                
                name: nil, focus: true
            )
            let opened = try #require(result.opened)
            let workspace = try #require(fixture.manager.workspacesById[opened.workspaceID])
            #expect(opened.workspaceID == pendingID)
            #expect(workspace.terminalPanel(for: opened.projections[0].panelID) === pendingPanel)
            #expect(relay?.pendingCount == 1, "Adoption must preserve the existing input relay")
            for revision in [10, 11, 12] {
                try fixture.provider.publish(revision: revision)
                await fixture.catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
                #expect(fixture.workspaces.count == 1)
                #expect(fixture.catalog.projections.count == 1)
                #expect(workspace.panels.count == 1)
                #expect(workspace.terminalPanel(for: opened.projections[0].panelID) === pendingPanel)
            }
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.provider.adoptedPanels == [opened.projections[0].panelID])
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
        }
    }

    @Test("Cancellation after a remote receipt returns closes the owned workspace and starter")
    func cancellationAfterReceiptCleansOwnedRemoteResources() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.beforeCreate = {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            await #expect(throws: CancellationError.self) {
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            let workspace = try #require(fixture.provider.createdWorkspaces.first)
            #expect(fixture.provider.closedWorkspaceIDs == [workspace.id])
            #expect(fixture.provider.closedTerminalIDs == [fixture.provider.terminal(in: workspace).id])
            #expect(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.isEmpty)
            #expect(fixture.manager.tabs.count == 1)
        }
    }

    @Test("Closing the early pane cleans a receipt that returns after cancellation")
    func cancellationWhileReceiptIsSuspendedCleansOwnedRemoteResources() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            let receiptCreated = RemoteLinkFirstValue<Bool>()
            let releaseReceipt = RemoteLinkFirstValue<Bool>()
            fixture.provider.afterCreateWorkspace = { _ in
                receiptCreated.resolve(true)
                _ = await releaseReceipt.result
            }
            let creation = Task { @MainActor in
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            #expect(await receiptCreated.result == true)
            let operation = try #require(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.values.first)
            let reservation = try #require(operation.reservation)
            reservation.cancel?()
            releaseReceipt.resolve(true)
            await #expect(throws: CancellationError.self) { try await creation.value }
            let workspace = try #require(fixture.provider.createdWorkspaces.first)
            #expect(fixture.provider.closedWorkspaceIDs == [workspace.id])
            #expect(fixture.provider.closedTerminalIDs == [fixture.provider.terminal(in: workspace).id])
            #expect(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.isEmpty)
        }
    }

    @Test("A provider error after local admission reaches the caller and remains retryable")
    func providerErrorAfterLocalAdmissionPropagates() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.beforeCreate = {
                throw TuiTransportError.placementMismatch
            }
            await #expect(throws: TuiTransportError.placementMismatch) {
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            #expect(fixture.manager.tabs.count == 2)
            let operation = try #require(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.values.first)
            #expect(operation.failure is TuiTransportError)
            #expect(operation.reservation != nil)
        }
    }

    @Test("Failed attachment or starter creation retries the same workspace and pending pane", arguments: [false, true], [false, true])
    func failedCreateRetainsItsReceiptForRetry(terminalFailure: Bool, retryFromAction: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.includesStarter = !terminalFailure
            if terminalFailure { fixture.provider.terminalError = TuiTransportError.placementMismatch }
            else { fixture.provider.beforeMaterialize = { _, _ in throw TuiTransportError.placementMismatch } }
            fixture.provider.beforeRefresh = {
                #expect(fixture.manager.tabs.count == 2)
                #expect(fixture.workspaces.count == 1, "An empty receipt must remain navigable while its starter is pending")
            }
            await #expect(throws: TuiTransportError.placementMismatch) {
                try await fixture.create(
                    
                    name: nil, focus: false, reuseFailedCreation: retryFromAction
                )
            }
            let pending = try #require(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.values.first)
            let reservation = try #require(pending.reservation)
            let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
            #expect(workspace.tuiMaterializationFailures[reservation.panelID] != nil)
            #expect(fixture.manager.tabs.count == 2 && fixture.workspaces.count == 1)
            #expect(fixture.catalog.projections.isEmpty)
            reservation.inputRelay.send(.bytes(Data("echo retry\n".utf8)))
            fixture.provider.terminalError = nil
            fixture.provider.beforeMaterialize = nil
            if retryFromAction {
                let result = try await fixture.create(
                    
                    name: nil, focus: false, reuseFailedCreation: true
                )
                #expect(result.opened?.workspaceID == reservation.workspaceID)
                #expect(result.opened?.projections.first?.panelID == reservation.panelID)
            } else {
                reservation.retry?()
                let retry = try #require(pending.retryTask)
                await retry.value
                #expect(fixture.catalog.projection(forPanel: reservation.panelID)?.workspaceID == reservation.workspaceID)
            }
            #expect(fixture.provider.createdWorkspaces.count == 1)
            #expect(Set(fixture.provider.terminalRequests).count == (terminalFailure ? 1 : 0))
            #expect(reservation.inputRelay.pendingCount == 1)
            #expect(workspace.tuiMaterializationFailures[reservation.panelID] == nil)
            try fixture.provider.publish(revision: 10)
            await fixture.catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.count == 1)
        }
    }

    @Test("Invalidated creates cannot resurrect a workspace from a late provider callback",
          arguments: ["cancel", "provider", "close", "daemon", "tab", "cursorless", "generation"])
    func staleCompletionCannotRestoreEitherProjection(reason: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.beforeMaterialize = { _, reservation in
                let reservation = try #require(reservation)
                switch reason {
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                case "provider": fixture.catalog.register(TuiPlacementTestProvider(machine: fixture.provider.machine))
                case "close":
                    let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                    fixture.manager.closeWorkspace(workspace, recordHistory: false)
                case "daemon": try fixture.provider.publish(revision: 10, includesWorkspaces: false)
                case "tab": try fixture.provider.publish(revision: 10, includesTabs: false)
                case "cursorless": try fixture.provider.publish(revision: 10, hasCursor: false)
                default: try fixture.provider.publish(revision: 1, includesWorkspaces: false, generation: "restarted")
                }
                // Deliberately return success even after invalidation, modelling an
                // uncooperative provider callback. The request fence owns admission.
            }
            let creation = Task { @MainActor in
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            await #expect(throws: CancellationError.self) { try await creation.value }
            #expect(fixture.manager.tabs.map(\.id) == [fixture.originalWorkspaceID])
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.isEmpty)
            #expect(fixture.catalog.tuiWorkspaceCreationCoordinator.operations.isEmpty)
        }
    }

    @Test("Overlapping creates finish out of order without sharing native or remote identities")
    func overlappingCreatesStayIndependent() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            let starts = AsyncStream<UUID>.makeStream()
            let gates = [RemoteLinkFirstValue<Bool>(), RemoteLinkFirstValue<Bool>()]
            fixture.provider.beforeMaterialize = { resource, reservation in
                let reservation = try #require(reservation)
                starts.continuation.yield(reservation.workspaceID)
                let index = try #require(resource.remoteWorkspace?.index)
                _ = await gates[index].result
            }
            let first = Task { @MainActor in
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            var events = starts.stream.makeAsyncIterator()
            let firstID = try #require(await events.next())
            let second = Task { @MainActor in
                try await fixture.create(
                    
                    name: nil, focus: false
                )
            }
            let secondID = try #require(await events.next())
            #expect(firstID != secondID)
            #expect(fixture.manager.tabs.count == 3)
            #expect(fixture.workspaces.count == 2)
            gates[1].resolve(true)
            let secondResult = try await second.value
            gates[0].resolve(true)
            let firstResult = try await first.value
            #expect(firstResult.opened?.workspaceID == firstID)
            #expect(secondResult.opened?.workspaceID == secondID)
            try fixture.provider.publish(revision: 10)
            await fixture.catalog.tuiWorkspaceProjectionCoordinator.waitForIdle()
            #expect(fixture.catalog.projections.count == 2)
            #expect(fixture.workspaces.count == 2)
            #expect(fixture.manager.tabs.count == 3)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.provider.terminalCreates == 0)
        }
    }



    @Test("The Cloud action uses its injected window even without a selected workspace", arguments: [false, true])
    func creationStaysInTheInitiatingWindow(hasSelection: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try TuiWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let other = TabManager()
            defer { other.tabs.forEach { $0.teardownAllPanels() } }
            fixture.app.tabManager = other
            if !hasSelection { fixture.manager.selectedTabId = nil }
            fixture.provider.usesReceipt = true
            let result = try await fixture.create(focus: true)
            #expect(result.opened != nil)
            #expect(fixture.manager.tabs.count == 2)
            #expect(other.tabs.count == 1)
            #expect(fixture.catalog.projections.allSatisfy { fixture.manager.workspacesById[$0.workspaceID] != nil })
        }
    }

}
