import AppKit
import CmuxControlCenter
import Foundation

extension ControlCenterCoordinator {
    func open(_ target: ControlCenterTarget) async {
        await runOperation(title: "Open \(target.name)") {
            _ = try await self.openTargetRecording(target)
        }
    }

    func createWorkspace(path: String, name: String, createDirectory: Bool) async {
        await runOperation(title: "Create \(name.isEmpty ? path : name)") {
            let target = ControlCenterTarget(name: name.isEmpty ? (path as NSString).lastPathComponent : name, kind: .newSession, path: path)
            if createDirectory {
                _ = try self.logicalDirectory(path, create: true)
                try await self.record(ControlCenterStep(targetID: target.id, title: "Prepare directory", status: .success, detail: "Directory is ready at \(path). Any created components remain if launch is cancelled or fails."))
            }
            _ = try await self.openTargetRecording(target)
        }
    }

    func collectionTitle(_ collection: ControlCenterCollection) -> String {
        "Collection: \(collection.name) [\(collection.id.uuidString)]"
    }

    func lastCollectionOperation(_ collection: ControlCenterCollection) -> ControlCenterOperation? {
        snapshot.operations.first { $0.title.hasSuffix("[\(collection.id.uuidString)]") }
    }

    func openCollection(_ collection: ControlCenterCollection, retryFailedOnly: Bool = false) async {
        let previous = lastCollectionOperation(collection)
        var receipts = collectionResults[collection.id] ?? [:]
        if receipts.isEmpty, let previous {
            for step in previous.steps {
                if let id = step.targetID { receipts[id] = step }
            }
        }
        await runOperation(title: collectionTitle(collection)) {
            try await self.launchCollection(collection, retryFailedOnly: retryFailedOnly, previous: receipts)
        }
    }

    func launchCollection(_ collection: ControlCenterCollection, retryFailedOnly: Bool, previous: [UUID: ControlCenterStep]) async throws {
        let items = retryFailedOnly ? collection.items.filter {
            previous[$0.id]?.status == .failed || previous[$0.id]?.status == .blocked
        } : collection.items
        guard !items.isEmpty else {
            throw ControlCenterHostError.blocked(retryFailedOnly ? "No failed or blocked targets from the latest collection run are available to retry." : "This collection has no targets.")
        }
        var latest = previous
        var receipt = ControlCenterOperation(title: collectionTitle(collection))
        let nested = operation?.title != receipt.title
        // Carry forward receipts so a later retry cannot forget successes or retry only
        // the most recent failed subset by accident.
        if retryFailedOnly {
            for item in collection.items where !items.contains(where: { $0.id == item.id }) {
                if let step = previous[item.id] {
                    try await record(step)
                    receipt.steps.append(step)
                }
            }
        }
        for (index, target) in items.enumerated() {
            if cancelled || Task.isCancelled {
                for remaining in items[index...] {
                    let step = ControlCenterStep(targetID: remaining.id, title: remaining.name, status: .cancelled, detail: "Not attempted. Completed targets were left open.")
                    latest[remaining.id] = step
                    try await record(step)
                    receipt.steps.append(step)
                    if nested { try await localStore().saveOperation(receipt) }
                }
                break
            }
            let step = try await openTargetRecording(target, prior: latest[target.id])
            latest[target.id] = step
            receipt.steps.append(step)
            if nested { try await localStore().saveOperation(receipt) }
        }
        collectionResults[collection.id] = latest
        guard !cancelled, !Task.isCancelled else { return }
        let workspaceIDs = collection.items.compactMap { item -> UUID? in
            guard latest[item.id]?.status == .success, let value = latest[item.id]?.workspaceID else { return nil }
            return UUID(uuidString: value)
        }
        for manager in tabManagers() {
            let members = workspaceIDs.filter { id in manager.tabs.contains { $0.id == id } }
            guard !members.isEmpty else { continue }
            let externalID = "control-center:\(collection.id.uuidString)"
            if let group = manager.workspaceGroups.first(where: { $0.externalID == externalID }) {
                for id in members { manager.addWorkspaceToGroup(workspaceId: id, groupId: group.id) }
            } else {
                guard manager.createWorkspaceGroup(name: collection.name, childWorkspaceIds: members, selectAnchor: false, externalID: externalID) != nil else {
                    try await record(ControlCenterStep(title: "Workspace group", status: .failed, detail: "Targets opened, but a native group could not be created. No targets were closed."))
                    continue
                }
            }
        }
    }

    @discardableResult
    func openTargetRecording(_ target: ControlCenterTarget, prior: ControlCenterStep? = nil) async throws -> ControlCenterStep {
        let step: ControlCenterStep
        do {
            try checkCancellation()
            let result = try await executeTarget(target, prior: prior)
            step = ControlCenterStep(targetID: target.id, title: target.name, status: .success, detail: result.detail, workspaceID: result.workspaceID?.uuidString)
        } catch {
            let status: ControlCenterStep.Status
            if cancelled || error is CancellationError { status = .cancelled }
            else if error is ControlCenterHostError { status = .blocked }
            else { status = .failed }
            step = ControlCenterStep(targetID: target.id, title: target.name, status: status, detail: error.localizedDescription)
        }
        try await record(step)
        return step
    }

    func executeTarget(_ target: ControlCenterTarget, prior: ControlCenterStep?) async throws -> (workspaceID: UUID?, detail: String) {
        if target.kind == .session {
            let result = try await focusOrResume(target)
            return (result.0, result.1)
        }
        let identity = target.kind == .newSession ? target.id.uuidString : (target.kind == .url ? target.path : canonicalPath(target.path))
        let key = target.kind.rawValue + ":" + identity
        if target.kind == .newSession { _ = try logicalDirectory(target.path) }
        let previousID = prior?.workspaceID.flatMap(UUID.init(uuidString:)) ?? openedTargets[key]
        if let previousID {
            for manager in tabManagers() {
                guard let workspace = manager.tabs.first(where: { $0.id == previousID }) else { continue }
                let matchesURL = target.kind == .url && workspace.panels.values.contains {
                    ($0 as? BrowserPanel)?.currentURL?.absoluteString == target.path
                }
                guard target.kind == .newSession || matchesURL else { continue }
                manager.focusTab(previousID)
                return (previousID, "Reused the target's existing workspace.")
            }
        }
        switch target.kind {
        case .session:
            preconditionFailure("Session handled above")
        case .directory:
            let path = try logicalDirectory(target.path)
            for manager in tabManagers() {
                if let workspace = manager.tabs.first(where: { !$0.isRemoteWorkspace && !$0.isRemoteTmuxMirror && canonicalPath($0.currentDirectory) == canonicalPath(path) }) {
                    manager.focusTab(workspace.id)
                    openedTargets[key] = workspace.id
                    return (workspace.id, "Focused a local workspace already in this directory.")
                }
            }
            let manager = try currentManager()
            guard let workspace = manager.addWorkspaceIfActive(title: target.name, workingDirectory: path, inheritWorkingDirectory: false) else {
                throw ControlCenterHostError.blocked("The directory workspace could not be created.")
            }
            openedTargets[key] = workspace.id
            return (workspace.id, "Opened local directory \(path).")
        case .newSession:
            let path = try logicalDirectory(target.path)
            let executable = try ompExecutable()
            let command = [executable.path, "--cwd", path].map(SessionEntry.shellQuote).joined(separator: " ")
            let manager = try currentManager()
            guard let workspace = manager.addWorkspaceIfActive(
                title: target.name,
                workingDirectory: path,
                initialTerminalInput: TerminalStartupTypedShellCommand().typedInput(posixCommand: command) + "\n",
                inheritWorkingDirectory: false
            ) else { throw ControlCenterHostError.blocked("The OMP workspace could not be created.") }
            openedTargets[key] = workspace.id
            return (workspace.id, "Submitted fresh OMP launch with logical --cwd \(path). Launch completion is not yet observed.")
        case .file:
            let path = (target.path as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw ControlCenterHostError.blocked("Choose an absolute file path.") }
            _ = try logicalDirectory((path as NSString).deletingLastPathComponent)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else { throw ControlCenterHostError.blocked("File is missing or unreadable: \(path)") }
            let manager = try currentManager()
            let workspace: Workspace?
            if let selected = manager.selectedWorkspace, !selected.isRemoteWorkspace, !selected.isRemoteTmuxMirror {
                workspace = selected
            } else {
                workspace = manager.addWorkspaceIfActive(workingDirectory: (path as NSString).deletingLastPathComponent, inheritWorkingDirectory: false)
            }
            guard let workspace,
                  let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
                  !workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true, reuseExisting: true).isEmpty else {
                throw ControlCenterHostError.blocked("A local built-in file preview could not be opened. Any created workspace was left intact.")
            }
            return (workspace.id, "Opened the built-in file preview for \(path).")
        case .url:
            guard let url = URL(string: target.path), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw ControlCenterHostError.blocked("Only HTTP(S) URLs without embedded credentials may be opened.")
            }
            guard BrowserAvailabilitySettings.isEnabled() else { throw ControlCenterHostError.blocked("The built-in browser is disabled.") }
            let manager = try currentManager()
            guard let workspace = manager.addWorkspaceIfActive(title: target.name, initialSurface: .browser, initialBrowserURL: url) else {
                throw ControlCenterHostError.blocked("The browser workspace could not be created.")
            }
            openedTargets[key] = workspace.id
            return (workspace.id, "Opened URL in the built-in browser.")
        }
    }
}
