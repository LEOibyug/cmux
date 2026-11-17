import CmuxControlCenter
import Darwin
import Foundation

private struct ControlCenterDirectoryArchivePlan: Decodable {
    struct Record: Decodable {
        let id: String
        let path: String
        let fingerprint: String
        let kind: String
        let reason: String
    }
    struct Session: Decodable {
        let sessionID: String
        let journalPath: String
        let cwd: String
        let newCwd: String
        let title: String
        let fingerprint: String
    }
    struct Directory: Decodable {
        let source: String
        let destination: String
        let fingerprint: String
        let sessions: [Session]
    }
    let digest: String
    let directories: [Directory]
    let warnings: [Record]
    let exclusions: [Record]
    let coverage: String
}

private struct ControlCenterDirectoryArchiveInvocation {
    let requestID: UUID
    let requestRoot: URL
    let result: [String: ControlCenterJSON]?
    let error: String?
}

extension ControlCenterCoordinator {
    func executeDirectoryArchive(_ call: ControlCenterToolCall) async throws -> ControlCenterJSON {
        let args = call.arguments.objectValue ?? [:]
        guard Set(args.keys).isSubset(of: ["paths", "destination", "exclude_records"]),
              let values = args["paths"]?.arrayValue, (1...32).contains(values.count) else {
            throw ControlCenterHostError.blocked("archive_directories requires 1–32 explicit project directory paths and an optional archive parent destination.")
        }
        let paths = try values.map { value in
            guard let path = value.stringValue, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlCenterHostError.blocked("Each paths entry must be an explicit absolute project directory path.")
            }
            return try logicalDirectory(path)
        }
        let exclusions: [String]
        if let value = args["exclude_records"] {
            guard let records = value.arrayValue else { throw ControlCenterHostError.blocked("exclude_records must be an array of exact issue IDs.") }
            exclusions = try records.map { value in
                guard let id = value.stringValue, id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
                    throw ControlCenterHostError.blocked("exclude_records requires exact current issue IDs explicitly selected by the user.")
                }
                return id
            }
            guard Set(exclusions).count == exclusions.count else { throw ControlCenterHostError.blocked("exclude_records must not contain duplicate IDs.") }
        } else { exclusions = [] }
        let scope = try sessionManagementScope()
        let destination: String
        if let value = args["destination"] {
            guard let path = value.stringValue, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlCenterHostError.blocked("destination must be an absolute archive parent directory path, or omitted for default_directory/Archived.")
            }
            destination = try logicalAbsolutePath(path)
        } else {
            destination = (scope.directory as NSString).appendingPathComponent("Archived")
        }
        guard paths.allSatisfy({ scope.contains($0) && canonicalPath($0) != scope.canonicalDirectory }),
              scope.contains(destination) else {
            throw ControlCenterHostError.blocked("Project folders and the archive parent must remain inside Connection's default directory; the scope root itself cannot be archived.")
        }
        let approvedConnection = connection
        let source = try await vaultIndex().ompMetadataSource()
        let addon = try managementExtension()
        let executable = try ompExecutable()
        let archiveRoot = try managedSessionRoot()
        let request: [String: ControlCenterJSON] = [
            "kind": .string("directory_archive"), "paths": .array(paths.map(ControlCenterJSON.string)),
            "destination": .string(destination), "sessionRoot": .string(source.root.path),
            "archiveRoot": .string(archiveRoot.path), "allowedCwdRoot": .string(scope.directory),
            "expectedCanonicalCwdRoot": .string(scope.canonicalDirectory),
            "exclude_records": .array(exclusions.map(ControlCenterJSON.string))
        ]
        // Planning is credentials-free and read-only for project folders and journals.
        let planning = try await invokeDirectoryArchive(request, action: "plan_directory_archive", executable: executable, addon: addon)
        guard let planned = planning.result, planned["ok"]?.boolValue == true,
              let planJSON = planned["plan"],
              let plan = try? JSONDecoder().decode(ControlCenterDirectoryArchivePlan.self, from: planJSON.data()),
              !plan.digest.isEmpty, plan.directories.count == paths.count,
              Set(plan.exclusions.map(\.id)) == Set(exclusions),
              plan.exclusions.count == exclusions.count,
              plan.coverage == (exclusions.isEmpty ? "complete" : "user_selected_partial"),
              Set(plan.directories.map { canonicalPath($0.source) }) == Set(paths.map { canonicalPath($0) }),
              plan.directories.allSatisfy({ directory in
                  scope.contains(directory.source) && scope.contains(directory.destination) &&
                  ControlCenterSessionScope.canonicalCwd(directory.destination) == ControlCenterSessionScope.canonicalCwd((destination as NSString).appendingPathComponent((directory.source as NSString).lastPathComponent)) &&
                  !directory.fingerprint.isEmpty && directory.sessions.allSatisfy {
                      !$0.sessionID.isEmpty && !$0.journalPath.isEmpty && !$0.fingerprint.isEmpty && scope.contains($0.cwd) && scope.contains($0.newCwd)
                  }
              }) else {
            var receipt = planning.result ?? [:]
            receipt["ok"] = .bool(false)
            receipt["status"] = .string("planning_failed")
            receipt["retry"] = .bool(false)
            receipt["error"] = .string(planning.result?["error"]?.stringValue ?? planning.error ?? "The installed worker returned an invalid directory archive plan. Update cmux-omp-extension, then review the requested folders again.")
            throw ControlCenterSessionManagementFailure(receipt: .object(receipt))
        }
        try checkCancellation()
        let sessionIDs = Set(plan.directories.flatMap { $0.sessions.map(\.sessionID) })
        guard sessionIDs.isDisjoint(with: uncertainSessionIDs) else {
            throw ControlCenterHostError.blocked("An associated conversation has an uncertain mutation result in this turn. Inspect its receipt and start a new explicit request before changing it again.")
        }
        let detailJSON: ControlCenterJSON = .object([
            "action": .string(call.name), "plan": planJSON,
            "directory_count": .number(Double(plan.directories.count)),
            "conversation_count": .number(Double(plan.directories.reduce(0) { $0 + $1.sessions.count })),
            "default_directory": .string(scope.directory), "canonical_scope": .string(scope.canonicalDirectory),
            "session_root": .string(source.root.path), "archive_root": .string(archiveRoot.path),
            "source_namespace": .string(source.namespace)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let detail = ControlCenterStrings.text("directoryArchiveDisclosure") + "\n\n" + String(decoding: try encoder.encode(detailJSON), as: UTF8.self)
        guard connection == approvedConnection, try sessionManagementScope() == scope, source.isCurrent else {
            throw ControlCenterHostError.blocked(ControlCenterStrings.text("approvalChanged"))
        }
        // This tool bypasses generic authorization; this is its only approval.
        try await authorizeTool(call, plannedDetail: detail)
        let currentSource = try await vaultIndex().ompMetadataSource()
        guard connection == approvedConnection, try sessionManagementScope() == scope,
              source.isCurrent, currentSource.namespace == source.namespace,
              try managementExtension() == addon, try ompExecutable() == executable else {
            throw ControlCenterHostError.blocked(ControlCenterStrings.text("approvalChanged"))
        }
        try checkCancellation()
        var executionRequest = request
        executionRequest["expectedPlanDigest"] = .string(plan.digest)
        let execution = try await invokeDirectoryArchive(executionRequest, action: "archive_directories", executable: executable, addon: addon)
        var receipt = execution.result ?? [
            "version": .number(1), "kind": .string("directory_archive"),
            "requestID": .string(execution.requestID.uuidString), "action": .string("archive_directories"),
            "ok": .bool(false), "outcome": .string("unknown"), "projects": .array([]),
            "error": .string(execution.error ?? "No trustworthy worker receipt was published. Inspect the operation and Pending sessions before any further mutation.")
        ]
        let projects = receipt["projects"]?.arrayValue ?? []
        let completeProjects = projects.count == plan.directories.count &&
            Set(projects.compactMap { $0.objectValue?["source"]?.stringValue }) == Set(plan.directories.map(\.source)) &&
            projects.allSatisfy { value in
                guard let project = value.objectValue,
                      let directory = plan.directories.first(where: { $0.source == project["source"]?.stringValue }),
                      project["destination"]?.stringValue == directory.destination,
                      project["status"]?.stringValue == "archived",
                      let sessions = project["sessions"]?.arrayValue,
                      sessions.count == directory.sessions.count else { return false }
                return sessions.allSatisfy { $0.objectValue?["ok"]?.boolValue == true && $0.objectValue?["state"]?.stringValue == "archived" }
            }
        let matchingCoverage = receipt["coverage"]?.stringValue == plan.coverage &&
            receipt["exclusions"] == planJSON.objectValue?["exclusions"] &&
            receipt["warnings"] == planJSON.objectValue?["warnings"]
        if receipt["ok"]?.boolValue == true, !completeProjects || !matchingCoverage {
            receipt["ok"] = .bool(false)
            receipt["outcome"] = .string("unknown")
            receipt["error"] = .string("The worker reported success without complete matching project/session, warning and exclusion coverage receipts. Preserve this receipt and refresh Pending sessions; do not retry automatically.")
        }
        let completed = receipt["ok"]?.boolValue == true && receipt["outcome"]?.stringValue != "unknown"
        let noMutation = receipt["ok"]?.boolValue == false && receipt["outcome"]?.stringValue == "preflight_failed" && receipt["mutationStarted"]?.boolValue == false
        receipt["retry"] = .bool(false)
        receipt["plan_digest"] = .string(plan.digest)
        receipt["plan"] = planJSON
        receipt["request_directory"] = .string(execution.requestRoot.path)
        if !completed {
            receipt["status"] = .string(receipt["outcome"]?.stringValue == "unknown" ? "unknown" : "incomplete")
            if receipt["error"] == nil { receipt["error"] = .string("Directory archival stopped. Inspect each project/session status; completed moves were not rolled back. No same-turn retry or compensation is allowed.") }
            if !noMutation { uncertainSessionIDs.formUnion(sessionIDs) }
        }
        // An independent task reconciles even if Stop cancelled the invoking model turn.
        let refreshError = await Task { @MainActor () -> String? in
            var errors: [String] = []
            do { try await OMPMetadataCoordinator.shared.refresh(source: source) }
            catch { errors.append(error.localizedDescription) }
            do { try await self.reconcileSessionInventory(source: source, scope: scope) }
            catch { errors.append(error.localizedDescription) }
            do {
                try await self.refreshSnapshot()
                if self.connection == approvedConnection {
                    try await self.findSessions(self.sessionQuery, agentID: "omp", state: self.sessionResultsState)
                }
            } catch { errors.append(error.localizedDescription) }
            return errors.isEmpty ? nil : errors.joined(separator: "\n")
        }.value
        if let refreshError { receipt["index_refresh_error"] = .string(refreshError) }
        if completed || noMutation { directoryArchiveMutationBlocked = false }
        let result = ControlCenterJSON.object(receipt)
        if !completed { throw ControlCenterSessionManagementFailure(receipt: result) }
        try await record(ControlCenterStep(title: ControlCenterStrings.text("approve.archive_directories"), status: .success,
            detail: String(decoding: try result.data(), as: UTF8.self)))
        return result
    }

    private func invokeDirectoryArchive(_ request: [String: ControlCenterJSON], action: String, executable: URL, addon: URL) async throws -> ControlCenterDirectoryArchiveInvocation {
        let requestID = UUID()
        let requestRoot = try dataDirectory().appendingPathComponent("OMPRequests", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requestRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var arguments = request
        arguments["version"] = .number(1)
        arguments["requestID"] = .string(requestID.uuidString)
        arguments["action"] = .string(action)
        let requestFile = requestRoot.appendingPathComponent("request.json")
        let resultFile = requestRoot.appendingPathComponent("result.json")
        try ControlCenterJSON.object(arguments).data().write(to: requestFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
        try checkCancellation()
        if action == "archive_directories" { directoryArchiveMutationBlocked = true }
        var invocationError: String?
        do {
            _ = try await ControlCenterOMPProbe().capture(executable: executable, arguments: [addon.path], directory: requestRoot,
                environment: ["BUN_BE_BUN": "1", "CMUX_OMP_REQUEST_FILE": requestFile.path, "CMUX_OMP_RESULT_FILE": resultFile.path], timeout: 120)
        } catch { invocationError = error.localizedDescription }
        var status = stat()
        var result: [String: ControlCenterJSON]?
        if lstat(resultFile.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o777 == 0o600,
           status.st_size <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: resultFile), let object = try? ControlCenterJSON.decode(data).objectValue,
           object["version"]?.numberValue == 1, object["kind"]?.stringValue == "directory_archive",
           UUID(uuidString: object["requestID"]?.stringValue ?? "") == requestID, object["action"]?.stringValue == action {
            result = object
        }
        if action == "plan_directory_archive" { try? FileManager.default.removeItem(at: requestRoot) }
        return ControlCenterDirectoryArchiveInvocation(requestID: requestID, requestRoot: requestRoot, result: result, error: invocationError)
    }
}
