import CmuxAgentSessionStore
import CmuxControlCenter
import Darwin
import Foundation

enum ControlCenterSessionListState: String, CaseIterable, Identifiable {
    case active, archived, trash, pending
    var id: String { rawValue }
    var managedState: OMPManagedSessionState? { OMPManagedSessionState(rawValue: rawValue) }
}

private struct ControlCenterOMPManifest: Decodable {
    let id: UUID
    let sessionID: String
    let title: String
    let cwd: String
    let originalJournalPath: String
    let journalPath: String
    let archiveDirectory: String
    let sourceRoot: String
    let state: OMPManagedSessionState
    let createdAt: Double
    let parentSession: String?

    func record(namespace: String) -> OMPManagedSessionRecord {
        OMPManagedSessionRecord(id: id, namespace: namespace, sessionID: sessionID, title: title,
            cwd: cwd, originalJournalPath: originalJournalPath, journalPath: journalPath.isEmpty ? originalJournalPath : journalPath,
            archiveDirectory: archiveDirectory, sourceRoot: sourceRoot, state: state,
            createdAt: Date(timeIntervalSince1970: createdAt), parentSession: parentSession)
    }
}

private struct ControlCenterOMPSelection {
    let id: UUID
    let sessionID: String
    let title: String
    let cwd: String
    let journal: String
    let fingerprint: String?
    let manifestFingerprint: String?
    let managed: OMPManagedSessionRecord?
}

struct ControlCenterSessionManagementFailure: LocalizedError {
    let receipt: ControlCenterJSON
    var errorDescription: String? {
        String(decoding: (try? receipt.data()) ?? Data(), as: UTF8.self)
    }
}

extension ControlCenterCoordinator {
    static func isSessionManagementTool(_ name: String) -> Bool {
        switch name {
        case "update_session_directory", "archive_session", "trash_session", "restore_session": return true
        default: return false
        }
    }

    func activeSessionSearchJSON() -> ControlCenterJSON {
        .array(sessions.map { target in
            let file = target.sessionFile ?? ""
            let prefix = sessionJournalRoot.map { $0 + "/" } ?? ""
            let relative = !prefix.isEmpty && file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : URL(fileURLWithPath: file).lastPathComponent
            return .object([
                "target_id": .string(target.id.uuidString), "session_id": target.sessionID.map(ControlCenterJSON.string) ?? .null,
                "name": .string(target.name), "cwd": .string(target.path), "journal": .string(relative),
                "storage_state": .string("active"),
                "modified_at": sessionModifiedAt[target.id].map { .string($0.ISO8601Format()) } ?? .null,
                "parent_session": sessionParents[target.id].map(ControlCenterJSON.string) ?? .null
            ])
        })
    }

    func managedSessionSearchJSON() -> ControlCenterJSON {
        .array(managedSessions.map { record in .object([
            "target_id": .string(record.id.uuidString), "session_id": .string(record.sessionID),
            "name": .string(record.title), "cwd": .string(record.cwd), "storage_state": .string(record.state.rawValue),
            "created_at": .string(record.createdAt.ISO8601Format()),
            "parent_session": record.parentSession.map(ControlCenterJSON.string) ?? .null
        ]) })
    }

    func reconcileSessionInventory(source: OMPMetadataCoordinator.Source, scope: ControlCenterSessionScope) async throws {
        try await reconcileManagedSessionManifests(source: source, scope: scope)
    }
    func sessionManagementScope() throws -> ControlCenterSessionScope {
        try ControlCenterSessionScope(directory: connection.defaultDirectory)
    }

    func scopedOMPMetadataPage(source: OMPMetadataCoordinator.Source, scope: ControlCenterSessionScope,
                               query: String, offset: Int, pageSize: Int) async throws -> (rows: [OMPSessionMetadataRecord], nextOffset: Int) {
        var cursor = offset
        var rows: [OMPSessionMetadataRecord] = []
        let batchSize = max(pageSize + 1, 64)
        while true {
            try Task.checkCancellation()
            let batch = try await OMPMetadataCoordinator.shared.search(source: source, query: query, cwd: nil,
                offset: cursor, limit: batchSize, canonicalCwdRoot: scope.canonicalDirectory)
            let validation = Task.detached(priority: .userInitiated) {
                batch.indices.filter { index in
                    let row = batch[index]
                    guard !Task.isCancelled, let header = SessionIndexStore.ompJournalHeader(URL(fileURLWithPath: row.journalPath)) else { return false }
                    return header.id == row.sessionID && scope.contains(header.cwd)
                }
            }
            let valid = await withTaskCancellationHandler { await validation.value } onCancel: { validation.cancel() }
            for index in valid {
                rows.append(batch[index])
                if rows.count > pageSize { return (rows, cursor + index) }
            }
            cursor += batch.count
            if batch.count < batchSize { return (rows, cursor) }
        }
    }

    func scopedOMPManagedPage(source: OMPMetadataCoordinator.Source, scope: ControlCenterSessionScope,
                              query: String, state: OMPManagedSessionState?, offset: Int, pageSize: Int) async throws -> (rows: [OMPManagedSessionRecord], nextOffset: Int) {
        var cursor = offset
        var rows: [OMPManagedSessionRecord] = []
        let batchSize = max(pageSize + 1, 64)
        while true {
            try Task.checkCancellation()
            let batch = try await OMPMetadataCoordinator.shared.managedSessions(source: source, query: query,
                state: state, offset: cursor, limit: batchSize, canonicalCwdRoot: scope.canonicalDirectory)
            for (index, row) in batch.enumerated() where scope.contains(row.cwd) {
                rows.append(row)
                if rows.count > pageSize { return (rows, cursor + index) }
            }
            cursor += batch.count
            if batch.count < batchSize { return (rows, cursor) }
        }
    }

    func searchScopedOMPContent(
        source: OMPMetadataCoordinator.Source, scope: ControlCenterSessionScope,
        query: String, offset: Int, limit: Int
    ) async throws -> [OMPSessionMetadataRecord] {
        var scanOffset = 0
        var skipped = 0
        var matches: [OMPSessionMetadataRecord] = []
        while matches.count < limit {
            try Task.checkCancellation()
            let batch = try await OMPMetadataCoordinator.shared.search(source: source, query: "", cwd: nil,
                offset: scanOffset, limit: 128, canonicalCwdRoot: scope.canonicalDirectory)
            if batch.isEmpty { break }
            let task = Task.detached(priority: .userInitiated) {
                batch.filter { row in
                    guard !Task.isCancelled, let header = SessionIndexStore.ompJournalHeader(URL(fileURLWithPath: row.journalPath)),
                          header.id == row.sessionID, scope.contains(header.cwd) else { return false }
                    return SessionIndexStore.fileContains(URL(fileURLWithPath: row.journalPath), needle: query)
                }
            }
            let found = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            for row in found {
                if skipped < offset { skipped += 1 } else if matches.count < limit { matches.append(row) }
            }
            scanOffset += batch.count
            if batch.count < 128 { break }
        }
        return matches
    }

    func refreshManagedSessions() async {
        guard !isRefreshingSessions else { return }
        isRefreshingSessions = true
        defer { isRefreshingSessions = false }
        do {
            let scope = try sessionManagementScope()
            let source = try await vaultIndex().ompMetadataSource()
            try await OMPMetadataCoordinator.shared.refresh(source: source)
            try await reconcileManagedSessionManifests(source: source, scope: scope)
            try await findSessions(sessionQuery, agentID: "omp", state: sessionListState)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func managedSessionRoot() throws -> URL {
        try dataDirectory().appendingPathComponent("ManagedSessions", isDirectory: true)
    }

    private func sessionFingerprint(_ journal: String) throws -> String {
        var status = stat()
        guard lstat(journal, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1 else {
            throw ControlCenterHostError.blocked("Select one regular OMP journal, not a link or alias copy.")
        }
        return "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)"
    }

    private func selectedManagedSession(_ call: ControlCenterToolCall) throws -> ControlCenterOMPSelection {
        let args = call.arguments.objectValue ?? [:]
        guard let raw = args["target_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw ControlCenterHostError.blocked("Choose an exact target_id returned by search_sessions.")
        }
        let scope = try sessionManagementScope()
        if call.name == "restore_session" {
            guard let saved = managedSessions.first(where: { $0.id == id }), scope.contains(saved.cwd),
                  saved.state != .restored else {
                throw ControlCenterHostError.blocked("Search the archive, trash or pending sessions first and select an exact result.")
            }
            let directory = URL(fileURLWithPath: saved.archiveDirectory).standardizedFileURL
            guard directory.deletingLastPathComponent().resolvingSymlinksInPath() == (try managedSessionRoot()).resolvingSymlinksInPath(),
                  directory.lastPathComponent.lowercased() == saved.id.uuidString.lowercased() else {
                throw ControlCenterHostError.blocked("The managed session location is invalid.")
            }
            let manifest = try readManagedManifest(directory)
            guard manifest.id == saved.id, manifest.sessionID == saved.sessionID,
                  canonicalPath(manifest.archiveDirectory) == directory.resolvingSymlinksInPath().path,
                  scope.contains(manifest.cwd), canonicalPath(manifest.sourceRoot) == canonicalPath(saved.sourceRoot) else {
                throw ControlCenterHostError.blocked("The saved session changed. Refresh the session list.")
            }
            let fingerprint = manifest.state == .pending && !FileManager.default.fileExists(atPath: manifest.journalPath)
                ? nil : try sessionFingerprint(manifest.journalPath)
            return ControlCenterOMPSelection(id: id, sessionID: manifest.sessionID, title: manifest.title,
                cwd: manifest.cwd, journal: manifest.journalPath.isEmpty ? manifest.originalJournalPath : manifest.journalPath,
                fingerprint: fingerprint, manifestFingerprint: try sessionFingerprint(directory.appendingPathComponent("manifest.json").path),
                managed: manifest.record(namespace: saved.namespace))
        }
        guard let target = sessions.first(where: { $0.id == id }), target.agentID == "omp",
              let sessionID = target.sessionID, let path = target.sessionFile,
              let header = SessionIndexStore.ompJournalHeader(URL(fileURLWithPath: path)), header.id == sessionID,
              scope.contains(header.cwd) else {
            throw ControlCenterHostError.blocked("Search first and select an exact OMP conversation in the default working directory.")
        }
        let fingerprint = try sessionFingerprint(path)
        guard sessionFingerprints[id] == fingerprint else {
            throw ControlCenterHostError.blocked("The conversation changed. Refresh its search result before managing it.")
        }
        return ControlCenterOMPSelection(id: id, sessionID: sessionID, title: target.name, cwd: header.cwd,
            journal: path, fingerprint: fingerprint, manifestFingerprint: nil, managed: nil)
    }

    func sessionManagementApprovalDetail(_ call: ControlCenterToolCall) throws -> String {
        let selected = try selectedManagedSession(call)
        let scope = try sessionManagementScope()
        let cwd = call.arguments.objectValue?["cwd"]?.stringValue
        if cwd != nil, call.name != "update_session_directory", call.name != "restore_session" {
            throw ControlCenterHostError.blocked("This operation does not change the conversation directory.")
        }
        if let cwd, !cwd.isEmpty {
            let destination = try logicalDirectory(cwd)
            guard scope.contains(destination) else {
                throw ControlCenterHostError.blocked("The destination must be inside the default working directory.")
            }
        }
        let detail: ControlCenterJSON = .object([
            "action": .string(call.name), "target_id": .string(selected.id.uuidString),
            "session_id": .string(selected.sessionID), "title": .string(selected.title),
            "journal": .string(canonicalPath(selected.journal)), "fingerprint": selected.fingerprint.map(ControlCenterJSON.string) ?? .null,
            "manifest_fingerprint": selected.manifestFingerprint.map(ControlCenterJSON.string) ?? .null,
            "cwd": .string(selected.cwd), "new_cwd": cwd.map(ControlCenterJSON.string) ?? .null,
            "canonical_new_cwd": cwd.map { .string(canonicalPath($0)) } ?? .null,
            "default_directory": .string(scope.directory), "canonical_scope": .string(scope.canonicalDirectory)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(detail), as: UTF8.self)
    }

    private func ensureOMPNotLoaded(_ sessionID: String) async throws {
        guard let live = await SharedLiveAgentIndex.shared.indexRefreshingNow(), live.isComplete else {
            throw ControlCenterHostError.blocked("Session ownership could not be verified. Try again after the session list refreshes.")
        }
        let isLoaded = await Task.detached(priority: .userInitiated) {
            live.liveSessionOwner(kind: "omp", sessionID: sessionID,
                processArgumentsProvider: { CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0) }) != nil
        }.value
        guard !isLoaded else {
            throw ControlCenterHostError.blocked("Close this OMP conversation before changing its data.")
        }
    }

    func managementExtension() throws -> URL {
        let path = ("~/.local/share/cmux-omp-extension/worker.mjs" as NSString).expandingTildeInPath
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_mode & 0o022 == 0 else {
            throw ControlCenterHostError.blocked("Install cmux-omp-extension before managing conversation data.")
        }
        return URL(fileURLWithPath: path)
    }

    private func readManagedManifest(_ directory: URL) throws -> ControlCenterOMPManifest {
        let file = directory.appendingPathComponent("manifest.json")
        var status = stat()
        guard lstat(file.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_size <= 65_536 else {
            throw ControlCenterHostError.blocked("The managed session manifest is unavailable.")
        }
        return try JSONDecoder().decode(ControlCenterOMPManifest.self, from: Data(contentsOf: file))
    }

    private func reconcileManagedSessionManifests(source: OMPMetadataCoordinator.Source, scope: ControlCenterSessionScope) async throws {
        let root = try managedSessionRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var manifests: [(manifest: ControlCenterOMPManifest, modified: Date)] = []
        var warnings: [String] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else { continue }
            do {
                let manifest = try readManagedManifest(directory)
                guard manifest.id == id, canonicalPath(manifest.sourceRoot) == source.canonicalRoot,
                      scope.contains(manifest.cwd) else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("manifest.json").path)
                manifests.append((manifest, attributes[.modificationDate] as? Date ?? Date.distantPast))
            } catch {
                warnings.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for item in manifests.sorted(by: { $0.modified < $1.modified }) {
            let manifest = item.manifest
            if manifest.state == .restored {
                try await localStore().updateSessionReferences(migrationID: manifest.id, sessionID: manifest.sessionID,
                    previousFile: canonicalPath(manifest.originalJournalPath), journal: manifest.journalPath, cwd: manifest.cwd)
                try await OMPMetadataCoordinator.shared.removeManagedSession(source: source, id: manifest.id)
            } else {
                do { try await OMPMetadataCoordinator.shared.saveManagedSession(source: source, record: manifest.record(namespace: source.namespace)) }
                catch let error as OMPSessionMetadataIndexError {
                    guard case .invalidManagedSession = error else { throw error }
                    warnings.append("\(manifest.id.uuidString): \(error.localizedDescription)")
                }
            }
        }
        sessionInventoryWarnings = warnings
    }

    func manageSession(_ name: String, targetID: UUID, cwd: String? = nil) async {
        await runOperation(title: ControlCenterStrings.text("approve." + name)) {
            var args: [String: ControlCenterJSON] = ["target_id": .string(targetID.uuidString)]
            if let cwd, !cwd.isEmpty { args["cwd"] = .string(cwd) }
            let call = ControlCenterToolCall(id: UUID().uuidString, name: name, arguments: .object(args))
            _ = try await self.executeSessionManagement(call)
        }
    }

    func executeSessionManagement(_ call: ControlCenterToolCall) async throws -> ControlCenterJSON {
        let addon = try managementExtension()
        let executable = try ompExecutable()
        let scope = try sessionManagementScope()
        let source = try await vaultIndex().ompMetadataSource()
        let selected = try selectedManagedSession(call)
        guard !uncertainSessionIDs.contains(selected.sessionID) else {
            throw ControlCenterHostError.blocked("This conversation has an uncertain result in this operation. A new explicit user request is required before another mutation.")
        }
        let approvedDetail = try sessionManagementApprovalDetail(call)
        try await ensureOMPNotLoaded(selected.sessionID)
        let canonicalJournal = canonicalPath(selected.journal)
        if selected.managed == nil {
            let root = source.canonicalRoot + "/"
            guard canonicalJournal.hasPrefix(root), (1...2).contains(canonicalJournal.dropFirst(root.count).split(separator: "/").count) else {
                throw ControlCenterHostError.blocked("This journal is outside the configured OMP session root.")
            }
        } else if selected.managed?.namespace != source.namespace {
            throw ControlCenterHostError.blocked("The session source changed. Refresh the session list.")
        }
        try await authorizeTool(call)
        guard try sessionManagementApprovalDetail(call) == approvedDetail,
              (try await vaultIndex().ompMetadataSource()).namespace == source.namespace else {
            throw ControlCenterHostError.blocked(ControlCenterStrings.text("approvalChanged"))
        }
        try await ensureOMPNotLoaded(selected.sessionID)
        let requestID = UUID()
        let root = try managedSessionRoot()
        let directory = selected.managed.map { URL(fileURLWithPath: $0.archiveDirectory) }
            ?? root.appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        let action: String
        switch call.name {
        case "update_session_directory": action = "change_directory"
        case "archive_session": action = "archive"
        case "trash_session": action = "trash"
        case "restore_session": action = "restore"
        default: throw ControlCenterHostError.blocked("Unsupported conversation operation.")
        }
        let requestedCwd = call.arguments.objectValue?["cwd"]?.stringValue
        if action == "change_directory", requestedCwd?.isEmpty != false {
            throw ControlCenterHostError.blocked("Choose the new conversation directory.")
        }
        let pending = selected.managed ?? OMPManagedSessionRecord(id: requestID, namespace: source.namespace,
            sessionID: selected.sessionID, title: selected.title, cwd: selected.cwd,
            originalJournalPath: canonicalJournal, journalPath: canonicalJournal,
            archiveDirectory: directory.path, sourceRoot: source.root.path, state: .pending,
            createdAt: Date(), parentSession: sessionParents[selected.id])
        var arguments: [String: ControlCenterJSON] = [
            "version": .number(1), "requestID": .string(requestID.uuidString), "action": .string(action),
            "sessionID": .string(selected.sessionID), "sessionFile": .string(canonicalJournal),
            "sessionRoot": .string(source.root.path), "archiveRoot": .string(root.path),
            "archiveDirectory": .string(directory.path), "title": .string(selected.title),
            "allowedCwdRoot": .string(scope.directory),
            "expectedCanonicalCwdRoot": .string(scope.canonicalDirectory)
        ]
        if let fingerprint = selected.fingerprint { arguments["expectedFingerprint"] = .string(fingerprint) }
        if let fingerprint = selected.manifestFingerprint { arguments["expectedManifestFingerprint"] = .string(fingerprint) }
        if let requestedCwd, !requestedCwd.isEmpty { arguments["newCwd"] = .string(try logicalDirectory(requestedCwd)) }
        let requestRoot = try dataDirectory().appendingPathComponent("OMPRequests", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requestRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let requestFile = requestRoot.appendingPathComponent("request.json")
        let resultFile = requestRoot.appendingPathComponent("result.json")
        try ControlCenterJSON.object(arguments).data().write(to: requestFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
        try await OMPMetadataCoordinator.shared.saveManagedSession(source: source, record: pending)
        uncertainSessionIDs.insert(selected.sessionID)
        let probe = ControlCenterOMPProbe()
        var invocationError: (any Error)?
        do {
            _ = try await probe.capture(executable: executable, arguments: [addon.path], directory: requestRoot,
                environment: ["BUN_BE_BUN": "1", "CMUX_OMP_REQUEST_FILE": requestFile.path, "CMUX_OMP_RESULT_FILE": resultFile.path], timeout: 120)
        } catch { invocationError = error }
        let result = try? ControlCenterJSON.decode(Data(contentsOf: resultFile))
        let object = result?.objectValue
        let identified = UUID(uuidString: object?["requestID"]?.stringValue ?? "") == requestID
        if !identified || object?["ok"]?.boolValue != true || object?["outcome"]?.stringValue == "unknown" {
            let noManifest = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
            let unchanged = selected.fingerprint != nil && (try? sessionFingerprint(selected.journal)) == selected.fingerprint
            if selected.managed == nil, noManifest, unchanged {
                try await OMPMetadataCoordinator.shared.removeManagedSession(source: source, id: pending.id)
                if FileManager.default.fileExists(atPath: directory.path),
                   try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.removeItem(at: requestRoot)
                uncertainSessionIDs.remove(selected.sessionID)
                if Task.isCancelled { throw CancellationError() }
                if let invocationError { throw invocationError }
                throw ControlCenterHostError.blocked(object?["error"]?.stringValue ?? "OMP declined the operation before changing the conversation.")
            }
            if identified, object?["outcome"]?.stringValue != "unknown", unchanged,
               let expected = selected.manifestFingerprint,
               (try? sessionFingerprint(directory.appendingPathComponent("manifest.json").path)) == expected {
                uncertainSessionIDs.remove(selected.sessionID)
                throw ControlCenterHostError.blocked(object?["error"]?.stringValue ?? "OMP declined the operation before changing the conversation.")
            }
            var receipt = identified ? (object ?? [:]) : [:]
            receipt["ok"] = .bool(false)
            receipt["retry"] = .bool(false)
            receipt["outcome"] = .string("unknown")
            receipt["state"] = .string("pending")
            receipt["archive_directory"] = .string(directory.path)
            receipt["error"] = .string(object?["error"]?.stringValue ?? invocationError?.localizedDescription ?? "The result is unknown. Refresh Pending sessions before another action.")
            do { try await reconcileManagedSessionManifests(source: source, scope: scope) }
            catch { receipt["index_refresh_error"] = .string(error.localizedDescription) }
            throw ControlCenterSessionManagementFailure(receipt: .object(receipt))
        }
        guard let result, let object else { throw ControlCenterHostError.blocked("Missing OMP result.") }
        var receipt = object
        do {
            try await reconcileManagedSessionManifests(source: source, scope: scope)
            let paths = [selected.journal, object["sessionFile"]?.stringValue].compactMap { $0 }
            try await OMPMetadataCoordinator.shared.refresh(source: source, journals: paths)
            try await refreshSnapshot()
            try await findSessions(sessionQuery, agentID: "omp", state: sessionResultsState)
        } catch { receipt["index_refresh_error"] = .string(error.localizedDescription) }
        let completed = ControlCenterJSON.object(receipt)
        try await record(ControlCenterStep(title: ControlCenterStrings.text("approve." + call.name), status: .success,
            detail: String(decoding: try completed.data(), as: UTF8.self)))
        uncertainSessionIDs.remove(selected.sessionID)
        if Task.isCancelled { throw CancellationError() }
        if receipt["index_refresh_error"] == nil { try FileManager.default.removeItem(at: requestRoot) }
        return completed
    }
}
