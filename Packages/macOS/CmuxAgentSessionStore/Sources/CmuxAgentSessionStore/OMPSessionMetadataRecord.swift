public import Foundation

/// Display metadata only. Journal admission and live ownership remain the caller's responsibility.
public struct OMPSessionMetadataRecord: Codable, Equatable, Sendable {
    public let journalPath: String
    public let sessionID: String
    public let title: String
    public let cwd: String?
    public let branch: String?
    public let modifiedAt: Date
    public let fingerprint: String
    public let parentSession: String?

    public init(
        journalPath: String,
        sessionID: String,
        title: String,
        cwd: String? = nil,
        branch: String? = nil,
        modifiedAt: Date,
        fingerprint: String,
        parentSession: String? = nil
    ) {
        self.journalPath = journalPath
        self.sessionID = sessionID
        self.title = String(title.prefix(512))
        self.cwd = cwd
        self.branch = branch
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.parentSession = parentSession
    }
}
