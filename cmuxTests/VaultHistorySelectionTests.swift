import Combine
import Foundation
import Testing
import CmuxAgentSessionStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct VaultHistorySelectionTests {
    private let defaultsDomain = "VaultHistorySelectionTests.\(UUID().uuidString)"
    enum ReadPath: CaseIterable {
        case initial, recent, directorySnapshot, directorySearch, explicitAgent, global, metadataOnly
    }

    @Test(arguments: ReadPath.allCases)
    func disabledSourcesAreNeverRead(path: ReadPath) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let fixture = VaultHistorySourceFixture(enabled: ["omp"])
        let store = try makeStore(fixture)
        await store.reload().value
        #expect(store.entries.map(\.agent.rawValue) == ["omp"])
        #expect(store.historyAgentOptions.contains { $0.id == "codex" })
        await fixture.clearRequests()

        let entries: [SessionEntry]
        switch path {
        case .initial:
            await store.reload().value
            entries = store.entries
        case .recent:
            entries = await store.loadRecentSessions(limitPerAgent: 10, offsetPerAgent: 4).entries
        case .directorySnapshot:
            entries = await store.loadDirectorySnapshot(cwd: "/fixture").entries
        case .directorySearch:
            entries = await store.searchSessions(
                query: "needle", scope: .directory("/fixture"), offset: 0, limit: 10
            ).entries
        case .explicitAgent:
            let disabled = await store.searchSessions(
                query: "needle", scope: .agent(.codex), offset: 0, limit: 10
            )
            #expect(disabled.entries.isEmpty)
            entries = await store.searchSessions(
                query: "needle", scope: .agent(.registered(RegisteredSessionAgent(id: "omp"))),
                offset: 0, limit: 10
            ).entries
        case .global:
            entries = await store.searchAllSessions(rawQuery: "needle").entries
        case .metadataOnly:
            let outcome = await SessionIndexStore.searchAllSessions(
                rawQuery: "agent:codex",
                entries: [VaultHistorySourceFixture.entry(.codex), VaultHistorySourceFixture.entry(.registered(RegisteredSessionAgent(id: "omp")))],
                scopedDirectory: nil,
                ampSessionRepository: AmpHookSessionRepository(),
                registry: await fixture.registry(),
                sourceReader: { await fixture.read($0) }
            )
            #expect(outcome.entries.isEmpty)
            #expect(await fixture.requests().isEmpty)
            return
        }
        #expect(entries.map(\.agent.rawValue) == ["omp"])
        let requests = await fixture.requests()
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.agent.rawValue == "omp" })
    }

    @Test
    func defaultNoneAndReenableTransitionsLoadOnlySelectedSources() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let fixture = VaultHistorySourceFixture(enabled: nil)
        let store = try makeStore(fixture)
        await store.reload().value
        #expect(Set(store.entries.map(\.agent.rawValue)) == ["codex", "omp"])
        #expect(Set(await fixture.requests().map(\.agent.rawValue)) == Set(SessionAgent.builtInCases.map(\.rawValue) + ["omp"]))

        await fixture.setEnabled([])
        await fixture.clearRequests()
        await store.refreshHistoryConfiguration()
        await waitUntilLoaded(store)
        #expect(store.entries.isEmpty)
        #expect(store.enabledAgentIDs == [])
        #expect(await fixture.requests().isEmpty)

        await fixture.setEnabled(["omp"])
        await store.refreshHistoryConfiguration()
        await waitUntilLoaded(store)
        #expect(store.entries.map(\.agent.rawValue) == ["omp"])
        #expect(await fixture.requests().allSatisfy { $0.agent.rawValue == "omp" })

        await fixture.setEnabled(nil)
        await store.refreshHistoryConfiguration()
        await waitUntilLoaded(store)
        #expect(store.enabledAgentIDs == nil)
        #expect(Set(store.entries.map(\.agent.rawValue)) == ["codex", "omp"])
    }

    @Test
    func disabledSourcesDisappearFromWarmCachesAndMetadataSearch() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let fixture = VaultHistorySourceFixture(enabled: nil)
        let store = try makeStore(fixture)
        await store.reload().value
        let initial = await store.loadDirectorySnapshot(cwd: "/fixture")
        #expect(Set(initial.entries.map(\.agent.rawValue)) == ["codex", "omp"])
        #expect(await store.searchAllSessions(rawQuery: "agent:codex").entries.count == 1)

        await fixture.setEnabled(["omp"])
        await fixture.clearRequests()
        await store.refreshHistoryConfiguration()
        #expect(store.entries.allSatisfy { $0.agent.rawValue == "omp" })
        await waitUntilLoaded(store)
        let enabled = await store.loadDirectorySnapshot(cwd: "/fixture")
        #expect(enabled.entries.map(\.agent.rawValue) == ["omp"])
        #expect(await store.searchAllSessions(rawQuery: "agent:codex").entries.isEmpty)
        #expect(await fixture.requests().allSatisfy { $0.agent.rawValue == "omp" })
    }

    enum RacePath: CaseIterable {
        case initial, directorySnapshot, agentSearch, globalSearch, recent
    }

    @Test(arguments: RacePath.allCases)
    func disableReenableDropsObsoleteResults(path: RacePath) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let fixture = VaultHistorySourceFixture(enabled: ["codex"])
        let store = try makeStore(fixture)
        await store.reload().value
        await fixture.holdNextCodexRead()

        let pending: Task<[SessionEntry], Never>
        switch path {
        case .initial:
            let reload = store.reload()
            #expect(store.entries.first?.title == "needle fresh", "Ordinary reload keeps the current entries")
            pending = Task { await reload.value; return [] }
        case .directorySnapshot:
            pending = Task { await store.loadDirectorySnapshot(cwd: "/fixture").entries }
        case .agentSearch:
            pending = Task {
                await store.searchSessions(query: "needle", scope: .agent(.codex), offset: 0, limit: 10).entries
            }
        case .globalSearch:
            pending = Task { await store.searchAllSessions(rawQuery: "needle").entries }
        case .recent:
            pending = Task { await store.loadRecentSessions(limitPerAgent: 10).entries }
        }
        await fixture.waitUntilHeld()
        await fixture.setEnabled([])
        await store.refreshHistoryConfiguration()
        #expect(store.entries.isEmpty, "Disable removes cached rows before the replacement load")
        await waitUntilLoaded(store)
        await fixture.setEnabled(["codex"])
        await store.refreshHistoryConfiguration()
        await waitUntilLoaded(store)
        #expect(store.entries.first?.title == "needle fresh")

        await fixture.releaseHeldRead()
        #expect(await pending.value.isEmpty, "A disable/reenable cycle cannot revive an old request")
        #expect(store.entries.first?.title == "needle fresh")
        let snapshot = await store.loadDirectorySnapshot(cwd: "/fixture")
        #expect(snapshot.entries.map(\.title) == ["needle fresh"], "Obsolete directory results never repopulate the cache")
    }

    @Test
    func explicitCaseSensitiveSelectionDoesNotEnableOtherIDs() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let fixture = VaultHistorySourceFixture(enabled: ["CODEX"])
        let store = try makeStore(fixture)
        await store.reload().value
        #expect(store.entries.isEmpty)
        #expect(await fixture.requests().isEmpty)
    }

    enum GenerationRacePath: CaseIterable {
        case initial, staticInitial, scopedSearch, globalSearch, staticGlobalSearch, directAgent, recent, directory
    }

    @Test(arguments: GenerationRacePath.allCases, [false, true])
    func fileGenerationFencesPendingReads(path: GenerationRacePath, reenable: Bool) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let config = try VaultHistoryConfigurationFixture()
        defer { try? FileManager.default.removeItem(at: config.home) }
        try config.setEnabled(["codex"])
        let registry = config.registry()
        let fixture = VaultHistorySourceFixture(enabled: ["codex"])
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let store = SessionIndexStore(
            registryProvider: { _ in config.registry() },
            sourceReader: { await fixture.read($0) },
            userDefaults: defaults,
            liveSessionKeysProvider: { [] },
            liveSessionNotifications: nil
        )
        await fixture.holdNextCodexRead()
        let pending = Task { () -> [SessionEntry] in
            switch path {
            case .initial:
                await store.reload().value
                return store.entries
            case .staticInitial:
                return await SessionIndexStore.loadInitialEntries(
                    ampSessionRepository: AmpHookSessionRepository(), registry: registry,
                    sourceReader: { await fixture.read($0) }
                )
            case .scopedSearch:
                return await store.searchSessions(
                    query: "needle secondary", scope: .agent(.codex), offset: 0, limit: 10
                ).entries
            case .globalSearch:
                return await store.searchAllSessions(rawQuery: "needle secondary").entries
            case .staticGlobalSearch:
                return await SessionIndexStore.searchAllSessions(
                    rawQuery: "needle secondary", entries: [], scopedDirectory: nil,
                    ampSessionRepository: AmpHookSessionRepository(), registry: registry,
                    sourceReader: { await fixture.read($0) }
                ).entries
            case .directAgent:
                return await SessionIndexStore.searchAgent(
                    needle: "needle", agent: .codex, cwdFilter: nil, offset: 0, limit: 10,
                    errorBag: SessionIndexStore.ErrorBag(), registry: registry,
                    ampSessionRepository: AmpHookSessionRepository(), sourceReader: { await fixture.read($0) }
                )
            case .recent:
                return await store.loadRecentSessions(limitPerAgent: 10).entries
            case .directory:
                return await store.loadDirectorySnapshot(cwd: "/fixture").entries
            }
        }
        await fixture.waitUntilHeld()
        try config.setEnabled([])
        if reenable { try config.setEnabled(["codex"]) }
        #expect(!registry.historyConfigurationIsCurrent)
        await fixture.releaseHeldRead()
        #expect(await pending.value.isEmpty)
        #expect(await fixture.requests().count == 1, "An obsolete multi-term request starts no further source reads")
    }

    @Test(arguments: [false, true])
    func obsoleteGenerationRefreshReplacesHeldLoadWithUnchangedSelection(coalescedToggle: Bool) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let config = try VaultHistoryConfigurationFixture()
        defer { try? FileManager.default.removeItem(at: config.home) }
        try config.setEnabled(["codex"])
        let fixture = VaultHistorySourceFixture(enabled: ["codex"])
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let store = SessionIndexStore(
            registryProvider: { _ in config.registry() },
            sourceReader: { await fixture.read($0) },
            userDefaults: defaults,
            liveSessionKeysProvider: { [] },
            liveSessionNotifications: nil
        )
        await store.reload().value
        let cached = await store.loadDirectorySnapshot(cwd: "/fixture")
        #expect(cached.entries.first?.title == "needle fresh")
        let revision = store.historyConfigurationRevision
        await fixture.holdNextCodexRead()
        let obsoleteLoad = store.reload()
        await fixture.waitUntilHeld()
        if coalescedToggle {
            try config.setEnabled([])
            try config.setEnabled(["codex"])
        } else {
            try config.setEnabled(["codex"], sidebarWidth: 280)
        }
        await fixture.setTitle("needle replacement")
        await store.refreshHistoryConfiguration()
        #expect(store.historyConfigurationRevision > revision)
        #expect(store.enabledAgentIDs == ["codex"])
        #expect(store.entries.first?.title == "needle fresh", "Enabled rows stay visible during replacement")
        await waitUntilLoaded(store)
        #expect(store.entries.first?.title == "needle replacement")
        await fixture.releaseHeldRead()
        await obsoleteLoad.value
        #expect(!store.isLoading)
        #expect(store.entries.first?.title == "needle replacement")
        #expect(await store.loadDirectorySnapshot(cwd: "/fixture").entries.first?.title == "needle replacement")
    }

    @Test(arguments: [false, true])
    func currentRefreshReplacesObsoleteFirstRegistryWithDefaultSelection(refreshBeforeRelease: Bool) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let config = try VaultHistoryConfigurationFixture()
        defer { try? FileManager.default.removeItem(at: config.home) }
        let configURL = config.home.appendingPathComponent(".config/cmux/cmux.json")
        try Data("{}".utf8).write(to: configURL, options: .atomic)
        let registryGate = VaultHistoryRegistryGate()
        let source = VaultHistorySourceFixture(enabled: nil)
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let store = SessionIndexStore(
            registryProvider: { _ in await registryGate.read(config.registry()) },
            sourceReader: { await source.read($0) },
            userDefaults: defaults,
            liveSessionKeysProvider: { [] },
            liveSessionNotifications: nil
        )
        let obsoleteLoad = store.reload()
        await registryGate.waitUntilHeld()
        #expect(await source.requests().isEmpty)
        try Data(#"{"app":{"globalFontMagnification":130}}"#.utf8).write(to: configURL, options: .atomic)
        if refreshBeforeRelease { await store.refreshHistoryConfiguration() }
        await registryGate.release()
        await obsoleteLoad.value
        if !refreshBeforeRelease { await store.refreshHistoryConfiguration() }
        await waitUntilLoaded(store)
        #expect(store.enabledAgentIDs == nil)
        #expect(!store.isLoading)
        #expect(Set(store.entries.map(\.agent.rawValue)) == ["codex", "omp"])
    }

    @Test(arguments: [false, true])
    func staleStaticRegistryCannotReadOrPublishMetadata(initiallyMissing: Bool) async throws {
        let config = try VaultHistoryConfigurationFixture()
        defer { try? FileManager.default.removeItem(at: config.home) }
        if !initiallyMissing { try config.setEnabled(["codex"]) }
        let registry = config.registry()
        try config.setEnabled([])
        let fixture = VaultHistorySourceFixture(enabled: ["codex"])
        let initial = await SessionIndexStore.loadInitialEntries(
            ampSessionRepository: AmpHookSessionRepository(), registry: registry,
            sourceReader: { await fixture.read($0) }
        )
        let metadata = await SessionIndexStore.searchAllSessions(
            rawQuery: "agent:codex", entries: [VaultHistorySourceFixture.entry(.codex)], scopedDirectory: nil,
            ampSessionRepository: AmpHookSessionRepository(), registry: registry,
            sourceReader: { await fixture.read($0) }
        )
        #expect(initial.isEmpty)
        #expect(metadata.entries.isEmpty)
        #expect(await fixture.requests().isEmpty)
    }

    @Test
    func fileChangeInvalidatesWarmDirectorySnapshotWithoutWatcherDelivery() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        let config = try VaultHistoryConfigurationFixture()
        defer { try? FileManager.default.removeItem(at: config.home) }
        try config.setEnabled(["codex"])
        let fixture = VaultHistorySourceFixture(enabled: ["codex"])
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let store = SessionIndexStore(
            registryProvider: { _ in config.registry() },
            sourceReader: { await fixture.read($0) },
            userDefaults: defaults,
            liveSessionKeysProvider: { [] },
            liveSessionNotifications: nil
        )
        #expect(await store.loadDirectorySnapshot(cwd: "/fixture").entries.count == 1)
        await fixture.clearRequests()
        try config.setEnabled([])
        #expect(await store.loadDirectorySnapshot(cwd: "/fixture").entries.isEmpty)
        #expect(await fixture.requests().isEmpty)
        try config.setEnabled(["codex"])
        #expect(await store.loadDirectorySnapshot(cwd: "/fixture").entries.count == 1)
        #expect(await fixture.requests().count == 1)
    }

    private func makeStore(_ fixture: VaultHistorySourceFixture) throws -> SessionIndexStore {
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        return SessionIndexStore(
            registryProvider: { _ in await fixture.registry() },
            sourceReader: { await fixture.read($0) },
            userDefaults: defaults,
            liveSessionKeysProvider: { [] },
            liveSessionNotifications: nil
        )
    }

    private func waitUntilLoaded(_ store: SessionIndexStore) async {
        for await loading in store.$isLoading.values {
            if !loading { return }
        }
    }
}

private actor VaultHistorySourceFixture {
    private var enabled: Set<String>?
    private var recordedRequests: [SessionIndexStore.SourceRequest] = []
    private var shouldHold = false
    private var heldRead: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var title = "needle fresh"

    init(enabled: Set<String>?) { self.enabled = enabled }

    func registry() -> CmuxVaultAgentRegistry {
        CmuxVaultAgentRegistry(registrations: [.builtInOmp], enabledAgentIDs: enabled)
    }

    func setEnabled(_ ids: Set<String>?) { enabled = ids }
    func clearRequests() { recordedRequests.removeAll() }
    func requests() -> [SessionIndexStore.SourceRequest] { recordedRequests }
    func setTitle(_ title: String) { self.title = title }
    func holdNextCodexRead() { shouldHold = true }

    func waitUntilHeld() async {
        if heldRead != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func releaseHeldRead() {
        heldRead?.resume()
        heldRead = nil
    }

    func read(_ request: SessionIndexStore.SourceRequest) async -> [SessionEntry] {
        recordedRequests.append(request)
        if request.agent == .codex && shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                heldRead = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
            return [Self.entry(request.agent, title: "needle stale")]
        }
        guard request.agent.rawValue == "codex" || request.agent.rawValue == "omp" else { return [] }
        return [Self.entry(request.agent, title: title)]
    }

    nonisolated static func entry(_ agent: SessionAgent, title: String = "needle fresh") -> SessionEntry {
        SessionEntry(
            id: "\(agent.rawValue):fixture", agent: agent, sessionId: "fixture", title: title,
            cwd: "/fixture", gitBranch: nil, pullRequest: nil, modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: agent == .codex
                ? .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
                : .registered(.builtInOmp)
        )
    }
}

private struct VaultHistoryConfigurationFixture: Sendable {
    let home: URL
    private let configURL: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configURL = home.appendingPathComponent(".config/cmux/cmux.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func setEnabled(_ ids: [String], sidebarWidth: Int? = nil) throws {
        var configuration: [String: Any] = ["vault": ["enabledAgents": ids]]
        if let sidebarWidth { configuration["sidebar"] = ["width": sidebarWidth] }
        let data = try JSONSerialization.data(withJSONObject: configuration)
        try data.write(to: configURL, options: .atomic)
    }

    func registry() -> CmuxVaultAgentRegistry {
        CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
    }
}

private actor VaultHistoryRegistryGate {
    private var isFirstRead = true
    private var heldRead: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    func read(_ registry: CmuxVaultAgentRegistry) async -> CmuxVaultAgentRegistry {
        if isFirstRead {
            isFirstRead = false
            await withCheckedContinuation { continuation in
                heldRead = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        return registry
    }

    func waitUntilHeld() async {
        if heldRead != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        heldRead?.resume()
        heldRead = nil
    }
}
