import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SurfaceCatalogQueryServiceTests {
    @Test("A configured SSH provider is resolved before its terminal is exported")
    func refreshedReadResolvesMissingSSHProvider() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.ssh("2232947c91a3d4142d388effe31813557f2fee6d01683b3a4100a6f07f9b81ae")
        let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { id in
            discoveries.append(id)
            catalog.register(provider)
        }

        // A user SSH connection may exist before its catalog provider is registered.
        #expect(catalog.provider(for: machine) == nil)
        let result = await query.read(machine: machine, refresh: true)

        #expect(discoveries == [machine.rawValue])
        #expect(provider.forcedRefreshes == [true])
        #expect(result.catalog.machines.map(\.id) == [machine])
        #expect(result.catalog.resources.map(\.id.key) == ["term-seeded"])
        #expect(result.catalog.projections.isEmpty)
        let payload = TerminalController.surfaceCatalogPayload(result, machine: machine)
        let resource = try #require((payload["resources"] as? [[String: Any]])?.first)
        #expect(resource["machine"] as? String == machine.rawValue)
        #expect((resource["remote_views"] as? [[String: Any]])?.first?["tab_id"] as? String == "tab-1")
    }

    @Test("A linked SSH read resolves and joins the current provider pass without forcing it")
    func linkedReadDiscoversAndJoinsCurrentPass() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.ssh("2232947c91a3d4142d388effe31813557f2fee6d01683b3a4100a6f07f9b81ae")
        let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { id in
            discoveries.append(id)
            catalog.register(provider)
        }

        // Link the explicitly requested SSH host before exporting its graph.
        let result = await query.read(machine: machine, mode: .linked)

        #expect(discoveries == [machine.rawValue])
        #expect(provider.forcedRefreshes == [false])
        let resource = try #require(result.catalog.resources.first)
        #expect(resource.remoteViews?.first?.workspace.id == "ws-1")
        #expect(resource.remoteViews?.first?.tabID == "tab-1")
    }

    @Test("Reopen: a linked read of an already-connected machine does no provider work")
    func linkedReadOfConnectedMachineIsFree() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.ssh("2e85c01c13185ce76f321769ce3ede6398670934755c415d003ae64a6134d74b")
        let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
        catalog.register(provider)
        await provider.refresh(force: false)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: machine, mode: .linked)

        #expect(discoveries.isEmpty)
        #expect(provider.forcedRefreshes == [false])
        #expect(result.catalog.resources.map(\.id.key) == ["term-seeded"])
    }

    @Test("A cached catalog read does not discover or wake an unknown machine")
    func cachedReadRemainsReadOnly() async {
        let catalog = SurfaceCatalog()
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: .ssh("2232947c91a3d4142d388effe31813557f2fee6d01683b3a4100a6f07f9b81ae"), refresh: false)

        #expect(discoveries.isEmpty)
        #expect(result.catalog == .empty)
    }

    @Test("Refreshing a known machine never waits on another machine's link")
    func knownProviderSkipsFleetDiscoveryAndOtherProviders() async throws {
        let catalog = SurfaceCatalog()
        let requested = try CloudCatalogQueryTestProvider(machine: .ssh("5afcb72598986ba03abd8b148d154169070cebf43dfc6b22bdf229779e97aaa2"), catalog: catalog)
        let unrelated = try CloudCatalogQueryTestProvider(machine: .ssh("37a9439d74d9153ee4157b4b004286c7aed5989e5cbbbca5095ada38d99780ba"), catalog: catalog)
        catalog.register(requested)
        catalog.register(unrelated)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        _ = await query.read(machine: requested.machine, refresh: true)

        #expect(discoveries.isEmpty)
        #expect(requested.forcedRefreshes == [true])
        #expect(unrelated.forcedRefreshes.isEmpty)
    }

    @Test("Failed discovery stays unavailable after one attempt and creates no resources")
    func failedDiscoveryDoesNotInventAnEmptyRemoteSession() async {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.ssh("d3460c6e36ebaebc1e3dfb0363875cacb3b4b0e4256d5ec6f4917d452af697ff")
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: machine, refresh: true)
        let payload = TerminalController.surfaceCatalogPayload(result, machine: machine)

        #expect(discoveries == [machine.rawValue])
        #expect(result.catalog == .empty)
        #expect((payload["resources"] as? [[String: Any]])?.isEmpty != false)
    }

    @Test("A missing local provider never triggers SSH resolution")
    func localReadStaysLocal() async {
        let catalog = SurfaceCatalog()
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        _ = await query.read(machine: .local, refresh: true)

        #expect(discoveries.isEmpty)
    }

    @Test("An unfiltered refresh still refreshes the registered catalog")
    func unfilteredReadRefreshesKnownProviders() async throws {
        let catalog = SurfaceCatalog()
        let provider = try CloudCatalogQueryTestProvider(machine: .ssh("42e1a3fb6e634cee0e1dca35462bbd8eed574459a474e217e64fe0765d206867"), catalog: catalog)
        catalog.register(provider)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: nil, refresh: true)

        #expect(discoveries.isEmpty)
        #expect(provider.forcedRefreshes == [true])
        #expect(result.catalog.resources.count == 1)
    }
}
