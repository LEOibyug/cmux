import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Muse Code Vault registration")
struct MuseVaultRegistrationTests {
    @Test("Built-in Muse registration is loaded and owns the muse resume kind")
    func builtInRegistrationIsLoaded() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-vault-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        let registration = try #require(registry.registration(id: "muse"))

        #expect(registration.isBuiltInMuse)
        #expect(registration.registeredResumeKind == .muse)
        #expect(registration.defaultExecutable == "muse")
        #expect(SessionSnapshotImportTrust.builtInRegistrationsByID["muse"] == .builtInMuse)
    }

    @Test("Vault lists top-level Muse sessions with a resume command in the session workspace")
    func vaultListsMuseSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("session-index.db", isDirectory: false)
        try exec(dbURL, """
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY, workspace_root TEXT, git_branch TEXT, title TEXT,
          session_name TEXT, first_user_prompt TEXT, search_text TEXT, prompt_count INTEGER,
          updated_at_us INTEGER, msp_kind TEXT, msp_parent_session_id TEXT
        );
        INSERT INTO sessions VALUES
          ('01a131ce-3556-7142-a0c8-c366cf09cfa5', '/work/muse repo', 'main', 'Ship Muse', NULL,
           'ship muse', 'ship muse', 3, 1700000200000000, NULL, NULL),
          ('child-session', '/work/muse repo', NULL, 'reminder', NULL, 'reminder', NULL, 1,
           1700000300000000, 'subagent', '01a131ce-3556-7142-a0c8-c366cf09cfa5');
        """)

        let outcome = SessionIndexStore.loadMuseEntriesForTesting(indexDBPath: dbURL.path)
        let entry = try #require(outcome.entries.first)

        #expect(outcome.errors.isEmpty)
        #expect(outcome.entries.count == 1)
        #expect(entry.agent == .registered(RegisteredSessionAgent(registration: .builtInMuse)))
        #expect(entry.title == "Ship Muse")
        #expect(entry.cwd == "/work/muse repo")
        #expect(entry.gitBranch == "main")
        let resume = try #require(entry.copyResumeCommand)
        #expect(
            resume
                == "cd -- '/work/muse repo' 2>/dev/null || [ ! -d '/work/muse repo' ] && 'muse' 'resume' '01a131ce-3556-7142-a0c8-c366cf09cfa5'"
        )
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }
}

@Suite("Vault global history selection")
struct VaultHistorySelectionConfigTests {
    @Test("Legacy and selection-only configs preserve missing-key semantics")
    func decodesOptionalSelection() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(CmuxVaultConfigDefinition.self, from: Data(#"{"agents":[]}"#.utf8))
        #expect(legacy.agents.isEmpty)
        #expect(legacy.enabledAgents == nil)
        let selection = try decoder.decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"enabledAgents":["omp","My.Agent"]}"#.utf8)
        )
        #expect(selection.agents.isEmpty)
        #expect(selection.enabledAgents == ["omp", "My.Agent"])
        let none = try decoder.decode(CmuxVaultConfigDefinition.self, from: Data(#"{"enabledAgents":[]}"#.utf8))
        #expect(none.enabledAgents == [])
        let roundTrip = try decoder.decode(CmuxVaultConfigDefinition.self, from: JSONEncoder().encode(selection))
        #expect(roundTrip == selection)
    }

    @Test("An explicit null selection is invalid rather than default-all")
    func rejectsNullSelection() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CmuxVaultConfigDefinition.self,
                from: Data(#"{"enabledAgents":null}"#.utf8)
            )
        }
    }

    @Test("Default includes future IDs and explicit selection is exact without removing registrations")
    func selectionDoesNotFilterRegistrations() {
        let all = CmuxVaultAgentRegistry(registrations: [.builtInOmp, .builtInPi])
        #expect(all.isHistoryEnabled(for: "future-agent"))
        #expect(all.historyConfigurationIsCurrent)
        let selected = CmuxVaultAgentRegistry(registrations: all.registrations, enabledAgentIDs: ["omp", "My.Agent"])
        #expect(selected.isHistoryEnabled(for: "omp"))
        #expect(selected.isHistoryEnabled(for: "My.Agent"))
        #expect(!selected.isHistoryEnabled(for: "my.agent"))
        #expect(!selected.isHistoryEnabled(for: "pi"))
        #expect(selected.registration(id: "pi") == .builtInPi)
        #expect(selected.registration(id: "omp") == .builtInOmp)
        let none = CmuxVaultAgentRegistry(registrations: all.registrations, enabledAgentIDs: [])
        #expect(!none.isHistoryEnabled(for: "omp"))
        #expect(none.registrations == all.registrations)
        #expect(none.historyConfigurationIsCurrent)
    }

    @Test("Only global selection applies during initial load and project merge")
    func projectCannotOverrideGlobalSelection() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-selection-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        let project = home.appendingPathComponent("project")
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"vault":{"enabledAgents":["omp"]}}"#.utf8).write(to: global)
        try Data(#"{"vault":{"enabledAgents":["pi"],"agents":[{"id":"custom","name":"Custom","sessionIdSource":"--session","resumeCommand":"custom {{sessionId}}"}]}}"#.utf8)
            .write(to: project.appendingPathComponent("cmux.json"))

        let loaded = CmuxVaultAgentRegistry.load(homeDirectory: home.path, workingDirectory: project.path, environment: [:])
        #expect(loaded.enabledAgentIDs == ["omp"])
        #expect(loaded.registration(id: "custom") != nil)
        #expect(loaded.registration(id: "pi") == .builtInPi)
        let globalOnly = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        let merged = globalOnly.mergingProjectConfig(workingDirectory: project.path)
        #expect(merged.enabledAgentIDs == ["omp"])
        #expect(merged.registration(id: "custom") != nil)
        #expect(loaded.historyConfigurationIsCurrent)
        #expect(merged.historyConfigurationIsCurrent)

        try Data(#"{"vault":{"enabledAgents":[]}}"#.utf8).write(to: global)
        #expect(!loaded.historyConfigurationIsCurrent)
        #expect(!merged.historyConfigurationIsCurrent)
        let staleMerge = globalOnly.mergingProjectConfig(workingDirectory: project.path)
        #expect(!staleMerge.historyConfigurationIsCurrent)
        #expect(staleMerge.enabledAgentIDs == ["omp"])
        let none = CmuxVaultAgentRegistry.load(homeDirectory: home.path, workingDirectory: project.path, environment: [:])
        #expect(none.enabledAgentIDs == [])
        #expect(!none.isHistoryEnabled(for: "omp"))
        try fm.removeItem(at: global)
        let defaultAll = CmuxVaultAgentRegistry.load(homeDirectory: home.path, workingDirectory: project.path, environment: [:])
        #expect(defaultAll.enabledAgentIDs == nil)
        #expect(defaultAll.isHistoryEnabled(for: "omp"))
        #expect(defaultAll.isHistoryEnabled(for: "custom"))
    }

    @Test("Present invalid global configs fail closed and restoration creates a new generation", arguments: [
        "",
        "{",
        #"{"vault":{"enabledAgents":null}}"#,
        #"{"vault":{"enabledAgents":"omp"}}"#,
        #"{"commands":42,"vault":{"enabledAgents":["omp"]}}"#,
    ])
    func invalidGlobalConfigFailsClosed(invalidContents: String) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-invalid-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        let validContents = Data(#"{"vault":{"enabledAgents":["omp"]}}"#.utf8)
        try validContents.write(to: global, options: .atomic)
        let original = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(original.enabledAgentIDs == ["omp"])
        #expect(original.historyConfigurationIsCurrent)

        try Data(invalidContents.utf8).write(to: global, options: .atomic)
        #expect(!original.historyConfigurationIsCurrent)
        let invalid = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(invalid.enabledAgentIDs == [])
        #expect(!invalid.isHistoryEnabled(for: "omp"))
        #expect(!invalid.isHistoryEnabled(for: "future-agent"))

        try validContents.write(to: global, options: .atomic)
        #expect(!original.historyConfigurationIsCurrent)
        #expect(!invalid.historyConfigurationIsCurrent)
        let restored = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(restored.enabledAgentIDs == ["omp"])
        #expect(restored.historyConfigurationIsCurrent)
    }

    @Test("A present global config that cannot provide file contents fails closed")
    func unreadableGlobalConfigFailsClosed() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-unreadable-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        try fm.createDirectory(at: global, withIntermediateDirectories: true)

        let unreadable = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(unreadable.enabledAgentIDs == [])
        #expect(!unreadable.isHistoryEnabled(for: "omp"))

        try fm.removeItem(at: global)
        try Data(#"{"vault":{"enabledAgents":["omp"]}}"#.utf8).write(to: global, options: .atomic)
        #expect(!unreadable.historyConfigurationIsCurrent)
        let restored = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(restored.enabledAgentIDs == ["omp"])
        #expect(restored.historyConfigurationIsCurrent)
    }

    @Test("Disabling and reenabling the same IDs invalidates atomic and in-place generations", arguments: [false, true])
    func selectionRoundTripInvalidatesGeneration(atomically: Bool) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-generation-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enabledContents = Data(#"{"vault":{"enabledAgents":["omp"]}}"#.utf8)
        let disabledContents = Data(#"{"vault":{"enabledAgents":[]}}"#.utf8)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try enabledContents.write(to: global)
        try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: global.path)
        let original = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(original.historyConfigurationIsCurrent)

        try writeConfig(disabledContents, to: global, atomically: atomically)
        try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: global.path)
        #expect(!original.historyConfigurationIsCurrent)
        let disabled = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(disabled.enabledAgentIDs == [])
        #expect(disabled.historyConfigurationIsCurrent)

        try writeConfig(enabledContents, to: global, atomically: atomically)
        try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: global.path)
        #expect(!original.historyConfigurationIsCurrent)
        #expect(!disabled.historyConfigurationIsCurrent)
        let restored = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(restored.enabledAgentIDs == original.enabledAgentIDs)
        #expect(restored.historyConfigurationIsCurrent)
    }

    @Test("Creating a formerly absent global config invalidates default-all snapshots")
    func missingGlobalConfigCreationInvalidatesGeneration() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-creation-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        let missing = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(missing.enabledAgentIDs == nil)
        #expect(missing.historyConfigurationIsCurrent)

        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"vault":{"enabledAgents":[]}}"#.utf8).write(to: global, options: .atomic)
        #expect(!missing.historyConfigurationIsCurrent)
        let created = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(created.enabledAgentIDs == [])
        #expect(created.historyConfigurationIsCurrent)
    }

    @Test("Creating and deleting a config does not revive a missing snapshot with an existing parent")
    func missingConfigRoundTripWithExistingParent() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-missing-parent-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        let parent = global.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: parent.path)
        let missing = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(missing.enabledAgentIDs == nil)
        #expect(missing.historyConfigurationIsCurrent)
        #expect(missing.historyConfigurationIsCurrent)

        try Data(#"{"vault":{"enabledAgents":[]}}"#.utf8).write(to: global)
        #expect(!missing.historyConfigurationIsCurrent)
        let disabled = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(disabled.enabledAgentIDs == [])
        #expect(disabled.historyConfigurationIsCurrent)

        try fm.removeItem(at: global)
        #expect(!missing.historyConfigurationIsCurrent)
        #expect(!disabled.historyConfigurationIsCurrent)
        let removed = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(removed.enabledAgentIDs == nil)
        #expect(removed.historyConfigurationIsCurrent)
    }

    @Test("Missing snapshots stay invalid after creating absent ancestors and removing the config or ancestors", arguments: [false, true])
    func missingConfigRoundTripWithAbsentAncestors(removeAncestors: Bool) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-missing-ancestors-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: home.path)
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        let missing = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(missing.enabledAgentIDs == nil)
        #expect(missing.historyConfigurationIsCurrent)
        #expect(missing.historyConfigurationIsCurrent)

        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(!missing.historyConfigurationIsCurrent)
        try Data(#"{"vault":{"enabledAgents":[]}}"#.utf8).write(to: global)
        #expect(!missing.historyConfigurationIsCurrent)
        let disabled = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(disabled.enabledAgentIDs == [])
        #expect(disabled.historyConfigurationIsCurrent)

        try fm.removeItem(at: removeAncestors ? home.appendingPathComponent(".config") : global)
        #expect(!missing.historyConfigurationIsCurrent)
        #expect(!disabled.historyConfigurationIsCurrent)
        let removed = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(removed.enabledAgentIDs == nil)
        #expect(removed.historyConfigurationIsCurrent)
    }

    @Test("Symlink target edits, retargeting, and dangling target creation invalidate snapshots")
    func symlinkTransitionsInvalidateGeneration() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cmux-history-symlink-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let global = home.appendingPathComponent(".config/cmux/cmux.json")
        let firstTarget = home.appendingPathComponent("first.json")
        let secondTarget = home.appendingPathComponent("second.json")
        let enabledContents = Data(#"{"vault":{"enabledAgents":["omp"]}}"#.utf8)
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enabledContents.write(to: firstTarget)
        try enabledContents.write(to: secondTarget)
        try fm.createSymbolicLink(at: global, withDestinationURL: firstTarget)
        let original = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(original.enabledAgentIDs == ["omp"])
        #expect(original.historyConfigurationIsCurrent)

        try Data(#"{"vault":{"enabledAgents":[]}}"#.utf8).write(to: firstTarget, options: .atomic)
        #expect(!original.historyConfigurationIsCurrent)
        let disabled = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(disabled.enabledAgentIDs == [])
        try enabledContents.write(to: firstTarget, options: .atomic)
        #expect(!original.historyConfigurationIsCurrent)
        #expect(!disabled.historyConfigurationIsCurrent)
        let restored = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(restored.historyConfigurationIsCurrent)

        try fm.removeItem(at: global)
        try fm.createSymbolicLink(at: global, withDestinationURL: secondTarget)
        #expect(!restored.historyConfigurationIsCurrent)
        let retargeted = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(retargeted.enabledAgentIDs == restored.enabledAgentIDs)
        #expect(retargeted.historyConfigurationIsCurrent)

        try fm.removeItem(at: secondTarget)
        #expect(!retargeted.historyConfigurationIsCurrent)
        let dangling = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(dangling.enabledAgentIDs == [])
        try enabledContents.write(to: secondTarget, options: .atomic)
        #expect(!dangling.historyConfigurationIsCurrent)
        let recreated = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])
        #expect(recreated.enabledAgentIDs == ["omp"])
        #expect(recreated.historyConfigurationIsCurrent)
    }

    private func writeConfig(_ contents: Data, to url: URL, atomically: Bool) throws {
        if atomically {
            try contents.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: contents)
            try handle.truncate(atOffset: UInt64(contents.count))
        }
    }
}
