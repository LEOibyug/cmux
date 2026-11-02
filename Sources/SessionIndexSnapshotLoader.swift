import CmuxAgentSessionStore

/// Explicit executor boundary for the Vault's initial filesystem snapshot.
struct SessionIndexSnapshotLoader: Sendable {
    typealias LoadOperation = @Sendable (
        any AmpHookSessionReading,
        CmuxVaultAgentRegistry?,
        SessionIndexStore.SourceReader?
    ) async -> [SessionEntry]

    private let loadOperation: LoadOperation

    init() {
        self.loadOperation = { repository, registry, sourceReader in
            await SessionIndexStore.loadInitialEntries(
                ampSessionRepository: repository,
                registry: registry,
                sourceReader: sourceReader
            )
        }
    }

    init(loadOperation: @escaping @Sendable () async -> [SessionEntry]) {
        self.loadOperation = { _, _, _ in await loadOperation() }
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func load(
        ampSessionRepository: any AmpHookSessionReading,
        registry: CmuxVaultAgentRegistry? = nil,
        sourceReader: SessionIndexStore.SourceReader? = nil
    ) async -> [SessionEntry] {
        await loadOperation(ampSessionRepository, registry, sourceReader)
    }
}
