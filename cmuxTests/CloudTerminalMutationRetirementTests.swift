import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal retirement regression", .timeLimit(.minutes(1)))
struct TuiTerminalMutationRetirementTests {
    @Test("Suspension cancels an admitted turn before it can mutate the machine")
    func suspensionCancelsAnAdmittedMutation() async {
        let catalog = SurfaceCatalog()
        let host = TuiTestHost(destination: "retirement-\(UUID()).example.test")
        let provider = CmuxTuiSurfaceProvider(
            summary: host.summary,
            links: host.links(),
            catalog: catalog
        )
        catalog.register(provider)
        defer {
            provider.retireTransport()
            catalog.unregister(machine: provider.machine)
        }
        var mutated = false
        let admitted = provider.terminalMutationQueue.enqueue { mutated = true }
        provider.retireTransport()
        #expect(admitted.isCancelled)
        await #expect(throws: CancellationError.self) { try await admitted.value }
        #expect(!mutated)
    }
}
