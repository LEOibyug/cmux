public import Foundation

public enum ControlCenterJSON: Codable, Equatable, Sendable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var objectValue: [String: Self]? {
        if case .object(let value) = self { return value }
        return nil
    }
    public var arrayValue: [Self]? {
        if case .array(let value) = self { return value }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

public struct ControlCenterTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case session, directory, file, url, newSession
    }

    public struct SessionIdentity: Equatable, Hashable, Sendable {
        public let agentID: String
        public let sessionID: String
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var path: String
    public var sessionID: String?
    public var sessionFile: String?
    public var agentID: String

    public var sessionIdentity: SessionIdentity? {
        guard kind == .session, let sessionID, !sessionID.isEmpty else { return nil }
        return SessionIdentity(agentID: agentID, sessionID: sessionID)
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, path: String, sessionID: String? = nil, sessionFile: String? = nil, agentID: String = "omp") {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.sessionID = sessionID
        self.sessionFile = sessionFile
        self.agentID = agentID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, path, sessionID, sessionFile, agentID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        path = try container.decode(String.self, forKey: .path)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sessionFile = try container.decodeIfPresent(String.self, forKey: .sessionFile)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID) ?? "omp"
    }
}

public struct ControlCenterCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [ControlCenterTarget]

    public init(id: UUID = UUID(), name: String, items: [ControlCenterTarget] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public struct ControlCenterPreference: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var scope: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), key: String, value: String, scope: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.key = key
        self.value = value
        self.scope = scope
        self.updatedAt = updatedAt
    }
}

public struct ControlCenterStep: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success, failed, blocked, cancelled
    }

    public var id: UUID
    public var targetID: UUID?
    public var title: String
    public var status: Status
    public var detail: String
    public var workspaceID: String?

    public init(id: UUID = UUID(), targetID: UUID? = nil, title: String, status: Status, detail: String, workspaceID: String? = nil) {
        self.id = id
        self.targetID = targetID
        self.title = title
        self.status = status
        self.detail = detail
        self.workspaceID = workspaceID
    }
}

public struct ControlCenterOperation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var steps: [ControlCenterStep]

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), steps: [ControlCenterStep] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.steps = steps
    }
}

public struct ControlCenterSnapshot: Codable, Equatable, Sendable {
    public var favorites: [ControlCenterTarget]
    public var collections: [ControlCenterCollection]
    public var preferences: [ControlCenterPreference]
    public var operations: [ControlCenterOperation]

    public init(favorites: [ControlCenterTarget] = [], collections: [ControlCenterCollection] = [], preferences: [ControlCenterPreference] = [], operations: [ControlCenterOperation] = []) {
        self.favorites = favorites
        self.collections = collections
        self.preferences = preferences
        self.operations = operations
    }
}

public struct ControlCenterConnection: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var ompExecutable: String
    public var defaultDirectory: String

    public init(baseURL: String = "http://127.0.0.1:17865/v1", model: String = "", apiKey: String = "", ompExecutable: String = "", defaultDirectory: String = "~/Work/temp") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.ompExecutable = ompExecutable
        self.defaultDirectory = defaultDirectory
    }
}

public struct ControlCenterTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: ControlCenterJSON

    public init(name: String, description: String, parameters: ControlCenterJSON) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ControlCenterToolCall: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var arguments: ControlCenterJSON

    public init(id: String, name: String, arguments: ControlCenterJSON) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ControlCenterModelTurn: Codable, Equatable, Sendable {
    public var output: [ControlCenterJSON]
    public var text: String
    public var calls: [ControlCenterToolCall]

    public init(output: [ControlCenterJSON] = [], text: String = "", calls: [ControlCenterToolCall] = []) {
        self.output = output
        self.text = text
        self.calls = calls
    }
}
