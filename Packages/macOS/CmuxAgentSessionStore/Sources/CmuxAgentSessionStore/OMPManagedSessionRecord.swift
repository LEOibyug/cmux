public import Foundation

public enum OMPManagedSessionState: String, Codable, CaseIterable, Sendable {
    case pending
    case archived
    case trash
    case restored
}

/// Durable stewardship intent and outcome; a pending record remains visible after interruption.
public struct OMPManagedSessionRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let namespace: String
    public let sessionID: String
    public let title: String
    public let cwd: String
    public let originalJournalPath: String
    public let journalPath: String
    public let archiveDirectory: String
    public let sourceRoot: String
    public let state: OMPManagedSessionState
    public let createdAt: Date
    public let parentSession: String?

    public init(
        id: UUID,
        namespace: String,
        sessionID: String,
        title: String,
        cwd: String,
        originalJournalPath: String,
        journalPath: String,
        archiveDirectory: String,
        sourceRoot: String,
        state: OMPManagedSessionState,
        createdAt: Date,
        parentSession: String? = nil
    ) {
        self.id = id
        self.namespace = namespace
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.originalJournalPath = originalJournalPath
        self.journalPath = journalPath
        self.archiveDirectory = archiveDirectory
        self.sourceRoot = sourceRoot
        self.state = state
        self.createdAt = createdAt
        self.parentSession = parentSession
    }
}
