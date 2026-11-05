struct CodexpressOperation: Decodable, Sendable {
    let id: String?
    let status: String?
    let result: Result?

    struct Result: Decodable, Sendable {
        let sources: [Source]
    }

    struct Source: Decodable, Sendable {
        let sourceID: String
        let status: String
        let code: String?
        let nextRetryAt: Double?

        private enum CodingKeys: String, CodingKey {
            case status, code
            case sourceID = "source_id"
            case nextRetryAt = "next_retry_at"
        }
    }
}
