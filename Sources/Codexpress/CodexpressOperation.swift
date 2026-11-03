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

        private enum CodingKeys: String, CodingKey {
            case status, code
            case sourceID = "source_id"
        }
    }
}
