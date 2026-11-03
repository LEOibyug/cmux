import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    static func descriptorChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        return normalizedPrevious.descriptor != current.descriptor
    }

    /// Ignores activity-only version bumps when deciding whether local projections changed.
    static func sidebarProjectionChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        normalizedPrevious.version = current.version
        return normalizedPrevious.hookStoreLookupSessionID != current.hookStoreLookupSessionID
            || normalizedPrevious.descriptor != current.descriptor
    }

}
