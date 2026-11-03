import CmuxRemoteSession
import CmuxTui
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal mutation lifecycle", .timeLimit(.minutes(1)))
struct TuiTerminalMutationLifecycleTests {
    @Test("Cancelling all turns keeps their predecessor chain until active work drains")
    func cancellationDoesNotReleaseSuccessorsEarly() async throws {
        let queue = TuiTerminalMutationQueue()
        let transport = TuiTerminalMutationTestTransport()
        var predecessorReturned = false
        var cancelledTurnRan = false
        let active = queue.enqueue {
            let data = try await transport.runTuiCommand(arguments: TuiRequest("workspace.run"), deadline: .seconds(30))
            predecessorReturned = true
            return data
        }
        let cancelledTurn = queue.enqueue {
            cancelledTurnRan = true
            return Data()
        }
        defer { queue.cancelAll(); transport.release() }
        try #require(await transport.started.result == true)
        queue.cancelAll()
        #expect(active.isCancelled && cancelledTurn.isCancelled)
        let replacementTurn = queue.enqueue {
            #expect(predecessorReturned, "A fresh turn must remain behind the cancelled active transport")
            return Data("new".utf8)
        }
        transport.release(Data("late old reply".utf8))
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await cancelledTurn.value }
        #expect(try await replacementTurn.value == Data("new".utf8))
        await queue.waitForIdle()
        #expect(!cancelledTurnRan)
    }

    @Test("A committed turn returns its receipt after queue cancellation")
    func committedTurnSurvivesCancellation() async throws {
        let queue = TuiTerminalMutationQueue()
        let started = RemoteLinkFirstValue<Bool>()
        let release = RemoteLinkFirstValue<String>()
        let task = Task {
            try await queue.runCommitted {
                started.resolve(true)
                // Model the transport waiter: it remains alive after the queue
                // turn is cancelled so a committed daemon response can still
                // be adopted or compensated by the caller.
                let response = Task.detached { await release.result ?? "missing" }
                return await response.value
            }
        }
        try #require(await started.result == true)
        queue.cancelAll()
        release.resolve("committed")
        #expect(try await task.value == "committed")
        await queue.waitForIdle()
    }

    @Test("Provider retirement rejects late command results and subsequent mutations",
          arguments: ["retire", "replace", "unregister"], ["session.snapshot", "workspace.run", "session.creation.resolve"])
    func commandAwaitIsFenced(change: String, operation: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = TuiTerminalMutationTestTransport()
        let lifecycle = provider.lifecycleGeneration
        let commands = TuiTerminalMutationCommandRunner(base: transport) {
            try provider.validateTerminalMutationLifecycle(lifecycle)
        }
        var published = false
        let task = provider.terminalMutationQueue.enqueue {
            _ = try await commands.runTuiCommand(arguments: TuiRequest(operation), deadline: .seconds(30))
            _ = try await commands.runTuiCommand(arguments: TuiRequest("pane.split"), deadline: .seconds(30))
            published = true
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.retireTransport()
            replacement?.retireTransport()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        switch change {
        case "retire": provider.retireTransport()
        case "replace": replacement = makeProvider(catalog: catalog, connection: provider.summary.connection)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.commands == [operation])
        #expect(!published)
        #expect(provider.pendingRemoteCreations.isEmpty)
        #expect(catalog.resources.isEmpty)
    }

    @Test("Retired and replaced providers reject creation before connecting",
          arguments: ["retire", "replace", "unregister"])
    func staleProviderNeverConnects(change: String) async {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        var replacement: CmuxTuiSurfaceProvider?
        switch change {
        case "retire": provider.retireTransport()
        case "replace": replacement = makeProvider(catalog: catalog, connection: provider.summary.connection)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        defer {
            provider.retireTransport()
            replacement?.retireTransport()
            catalog.unregister(machine: provider.machine)
        }
        // The real SSH test carrier cannot connect; cancellation must precede dialing it.
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(nearTabID: "tab", splitDirection: .right)
        }
    }

    @Test("A queued provider create cannot enter a replaced lifecycle",
          arguments: [false, true], ["retire", "replace"])
    func queuedCreationKeepsItsAdmittedLifecycle(layout: Bool, change: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = TuiTerminalMutationTestTransport()
        let blockingTurn = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: TuiRequest("workspace.run"), deadline: .seconds(30))
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.retireTransport()
            replacement?.retireTransport()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        let admitted = RemoteLinkFirstValue<Bool>()
        let request = Task {
            admitted.resolve(true)
            if layout { return try await provider.createTerminal(nearTabID: "tab", splitDirection: .right) }
            return try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        try #require(await admitted.result == true)
        if change == "retire" {
            provider.retireTransport()
        } else {
            replacement = makeProvider(catalog: catalog, connection: provider.summary.connection)
        }
        transport.release()
        _ = try? await blockingTurn.value
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test("A replacement accepts new work without reviving the retired provider's queue")
    func retirementInvalidatesQueuedWorkAcrossReplacement() async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = TuiTerminalMutationTestTransport()
        let oldGeneration = provider.lifecycleGeneration
        var queuedRan = false
        let active = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: TuiRequest("workspace.run"), deadline: .seconds(30))
        }
        let queued = provider.terminalMutationQueue.enqueue { queuedRan = true }
        defer {
            provider.retireTransport()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        provider.retireTransport()
        #expect(active.isCancelled && queued.isCancelled)
        let replacement = makeProvider(catalog: catalog, connection: provider.summary.connection)
        defer { replacement.retireTransport() }
        #expect(throws: CancellationError.self) { try provider.validateTerminalMutationLifecycle(oldGeneration) }
        let generation = replacement.lifecycleGeneration
        let next = replacement.terminalMutationQueue.enqueue {
            try replacement.validateTerminalMutationLifecycle(generation)
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await next.value
        #expect(!queuedRan)
        await provider.stop()
    }


    private func makeProvider(catalog: SurfaceCatalog, connection: SSHTuiConnection? = nil) -> CmuxTuiSurfaceProvider {
        let host = connection.map(TuiTestHost.init(connection:)) ?? TuiTestHost(destination: "mutation-\(UUID()).example.test")
        let provider = CmuxTuiSurfaceProvider(
            summary: host.summary,
            links: host.links(),
            catalog: catalog
        )
        catalog.register(provider)
        return provider
    }

}
