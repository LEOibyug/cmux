import Foundation
import CmuxAgentSessionStore

// MARK: - Global (cross-agent) session search for the recency "All" view and
// the `cmux vault search` socket surface.

extension SessionIndexStore {
    /// Per-agent cap for the transcript-content phase of a global search.
    nonisolated static let globalSearchPerAgentLimit = 50
    /// Overall cap on merged global search results.
    nonisolated static let globalSearchResultCap = 200
    /// Transcript searches run per free-text term; only the most selective
    /// (longest) few terms fan out to keep total work bounded.
    nonisolated static let globalSearchMaxTranscriptTerms = 3

    /// Instance wrapper used by the Vault UI: searches over the loaded index
    /// with the store's folder scope applied.
    func searchAllSessions(rawQuery: String) async -> SearchOutcome {
        let generation = historyConfigurationRevision
        let registry = await registryProvider(scopeToCurrentDirectory ? currentDirectory : nil)
        guard generation == historyConfigurationRevision, !Task.isCancelled,
              registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        let outcome = await Self.searchAllSessions(
            rawQuery: rawQuery,
            entries: entries,
            scopedDirectory: scopeToCurrentDirectory ? currentDirectory : nil,
            ampSessionRepository: ampSessionRepository,
            registry: registry,
            sourceReader: sourceReader
        )
        guard generation == historyConfigurationRevision, !Task.isCancelled,
              registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        return outcome
    }

    /// Loads a larger bounded recent-session slice for callers that have
    /// exhausted the initial Vault preview. This deliberately reuses the same
    /// per-agent readers, registry, caps, and error policy as Vault instead of
    /// introducing a second history index.
    func loadRecentSessions(
        limitPerAgent: Int,
        offsetPerAgent: Int = 0
    ) async -> SearchOutcome {
        let generation = historyConfigurationRevision
        let safeLimit = min(max(limitPerAgent, 1), Self.searchMaxFiles)
        let safeOffset = min(max(offsetPerAgent, 0), Self.searchMaxFiles)
        let bag = ErrorBag()
        let order = Self.agentOrder(registry: await registryProvider(nil))
        guard generation == historyConfigurationRevision, !Task.isCancelled,
              order.registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        let combined = await Self.loadAgents(
            order.agents,
            registry: order.registry,
            ampSessionRepository: ampSessionRepository,
            needle: "",
            cwdFilter: nil,
            offset: safeOffset,
            limit: safeLimit,
            errorBag: bag,
            sourceReader: sourceReader
        )
        guard !Task.isCancelled, generation == historyConfigurationRevision,
              order.registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        return SearchOutcome(
            entries: combined.sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.id < rhs.id
            },
            errors: bag.snapshot()
        )
    }

    /// Store-free core (also the `vault.search` socket handler's engine).
    /// Two bounded phases: metadata match against `entries`, then the
    /// existing capped per-agent transcript search for the free-text part of
    /// the query (issue #4535: no new scan primitives, existing caps reused).
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func searchAllSessions(
        rawQuery: String,
        entries: [SessionEntry],
        scopedDirectory: String?,
        ampSessionRepository: any AmpHookSessionReading,
        registry suppliedRegistry: CmuxVaultAgentRegistry? = nil,
        sourceReader: SourceReader? = nil
    ) async -> SearchOutcome {
        let query = VaultSessionSearchQuery.parse(rawQuery)
        guard !query.isEmpty else {
            return SearchOutcome(entries: [], errors: [])
        }

        let registry: CmuxVaultAgentRegistry
        if let suppliedRegistry { registry = suppliedRegistry }
        else { registry = await vaultAgentRegistry(workingDirectory: scopedDirectory) }
        guard !Task.isCancelled, registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        var merged = entries.filter {
            registry.isHistoryEnabled(for: $0.agent.rawValue) && query.matchesMetadata($0)
        }
        var errors: [String] = []

        // Transcript phase: the underlying per-agent search matches one
        // literal needle, so a multi-word query runs one bounded search per
        // term (the most selective few) and intersects the results — "flaky
        // test" finds transcripts containing both words, not only the exact
        // phrase. The per-agent caps make this an approximation for terms
        // with more matches than the cap; that is the bounded-work tradeoff.
        let needleTerms = Array(
            query.textTerms
                .sorted { $0.count > $1.count }
                .prefix(Self.globalSearchMaxTranscriptTerms)
        )
        if !needleTerms.isEmpty {
            let agents = globalSearchCandidateAgents(for: query, registry: registry)
            var perTermIDs: [Set<String>] = []
            var transcriptEntriesByID: [String: SessionEntry] = [:]
            for term in needleTerms {
                // A cancelled search must not merge partial per-term results —
                // an intersection over fewer terms admits entries that only
                // match a subset of the query.
                guard !Task.isCancelled, registry.historyConfigurationIsCurrent else {
                    return SearchOutcome(entries: [], errors: [])
                }
                let bag = ErrorBag()
                let outcomes = await withTaskGroup(of: [SessionEntry].self) { group in
                    for agent in agents {
                        // Grok and registered agents take the folder scope as
                        // their cwd filter, mirroring `searchSessions`'s
                        // per-scope behavior.
                        let cwdFilter: String?
                        switch agent {
                        case .grok, .registered:
                            cwdFilter = scopedDirectory
                        default:
                            cwdFilter = nil
                        }
                        group.addTask {
                            await Self.searchAgent(
                                needle: term.lowercased(),
                                agent: agent,
                                cwdFilter: cwdFilter,
                                offset: 0,
                                limit: Self.globalSearchPerAgentLimit,
                                errorBag: bag,
                                registry: registry,
                                ampSessionRepository: ampSessionRepository,
                                sourceReader: sourceReader
                            )
                        }
                    }
                    var collected: [[SessionEntry]] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                // A cancellation can arrive while the task group drains its
                // children. Do not merge the completed subset into an
                // intersection that no longer represents the full query.
                guard !Task.isCancelled, registry.historyConfigurationIsCurrent else {
                    return SearchOutcome(entries: [], errors: [])
                }
                errors.append(contentsOf: bag.snapshot())
                var termIDs: Set<String> = []
                for result in outcomes {
                    for entry in result where query.matchesOperators(entry) {
                        termIDs.insert(entry.id)
                        transcriptEntriesByID[entry.id] = entry
                    }
                }
                perTermIDs.append(termIDs)
                guard !Task.isCancelled, registry.historyConfigurationIsCurrent else {
                    return SearchOutcome(entries: [], errors: [])
                }
            }
            if let first = perTermIDs.first {
                let intersected = perTermIDs.dropFirst().reduce(first) { $0.intersection($1) }
                merged.append(contentsOf: intersected.compactMap { transcriptEntriesByID[$0] })
            }
        }

        if let scoped = Self.normalizedGlobalSearchDirectory(scopedDirectory) {
            merged = merged.filter { entry in
                guard let cwd = Self.normalizedGlobalSearchDirectory(entry.cwd) else { return false }
                return cwd == scoped || cwd.hasPrefix(scoped + "/")
            }
        }

        let ranked = VaultSessionSearchRanking.rank(merged, query: query)
        guard !Task.isCancelled, registry.historyConfigurationIsCurrent else {
            return SearchOutcome(entries: [], errors: [])
        }
        return SearchOutcome(
            entries: Array(ranked.prefix(Self.globalSearchResultCap)),
            errors: errors.sorted()
        )
    }

    /// Enabled agents worth fanning the transcript search across, narrowed by
    /// `agent:` operators when present.
    nonisolated private static func globalSearchCandidateAgents(
        for query: VaultSessionSearchQuery,
        registry: CmuxVaultAgentRegistry
    ) -> [SessionAgent] {
        let agents = agentOrder(registry: registry).agents
        guard !query.agentTerms.isEmpty else { return agents }
        return agents.filter { agent in
            let rawValue = agent.rawValue.lowercased()
            let display = agent.displayName.lowercased()
            return query.agentTerms.contains { rawValue.contains($0) || display.contains($0) }
        }
    }

    nonisolated private static func normalizedGlobalSearchDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var path = (value as NSString).standardizingPath
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
