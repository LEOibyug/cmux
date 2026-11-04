import Foundation

/// Identifies the existing SSH cmux-tui workspace mirrored by a local workspace.
struct RemoteWorkspaceBinding: Equatable, Sendable {
    let machineID: String
    let remoteWorkspaceID: String?

    init(machineID: String, remoteWorkspaceID: String? = nil) {
        self.machineID = machineID
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    static func normalizedMachineID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.range(of: "^ssh:[a-f0-9]{64}\\z", options: .regularExpression) != nil else { return nil }
        return trimmed
    }
}
