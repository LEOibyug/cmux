struct CodexpressResetRequest: Decodable, Sendable, Equatable {
    let id: String
    let sourceID: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id, status
        case sourceID = "source_id"
    }
}
