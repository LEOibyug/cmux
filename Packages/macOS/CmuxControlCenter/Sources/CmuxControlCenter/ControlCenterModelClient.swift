public import Foundation

public enum ControlCenterModelError: Error, LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case missingModel
    case invalidAPIKey
    case invalidInput
    case invalidToolSchema
    case transport(Int)
    case httpStatus(Int)
    case invalidResponse
    case responseFailed
    case incompleteResponse
    case invalidToolArguments

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Enter an HTTP or HTTPS API base URL without embedded credentials, query, or fragment."
        case .missingModel: return "Choose or enter a model before starting a model operation."
        case .invalidAPIKey: return "The API key contains invalid header characters."
        case .invalidInput: return "The model request contains a value that cannot be encoded as JSON."
        case .invalidToolSchema: return "A model tool has an invalid parameter schema."
        case .transport(let code): return "The model connection failed (network \(code)). No automatic retry was attempted."
        case .httpStatus(let code): return "The model server returned HTTP \(code). No automatic retry was attempted."
        case .invalidResponse: return "The model server returned an invalid response."
        case .responseFailed: return "The model server reported a failed response."
        case .incompleteResponse: return "The model response did not complete."
        case .invalidToolArguments: return "The model returned invalid tool arguments. No tools from this turn were executed."
        }
    }
}

public final class ControlCenterModelClient: Sendable {
    private let connection: ControlCenterConnection
    private let session: URLSession

    public init(connection: ControlCenterConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: ControlCenterHTTPDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func models() async throws -> [String] {
        let data = try await send(request(endpoint: "models"))
        guard let object = try Self.json(data).objectValue,
              let entries = object["data"]?.arrayValue else {
            throw ControlCenterModelError.invalidResponse
        }
        var seen: Set<String> = []
        var identifiers: [String] = []
        for entry in entries {
            guard let id = entry.objectValue?["id"]?.stringValue, !id.isEmpty else {
                throw ControlCenterModelError.invalidResponse
            }
            if seen.insert(id).inserted { identifiers.append(id) }
        }
        return identifiers
    }

    public func respond(
        input: [ControlCenterJSON],
        tools: [ControlCenterTool],
        operationID: UUID,
        onTextDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ControlCenterModelTurn {
        guard !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlCenterModelError.missingModel
        }
        let toolJSON: [ControlCenterJSON] = try tools.map { tool in
            guard tool.parameters.objectValue != nil else { throw ControlCenterModelError.invalidToolSchema }
            return .object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters
            ])
        }
        let body = ControlCenterJSON.object([
            "model": .string(connection.model),
            "input": .array(input),
            "tools": .array(toolJSON),
            "stream": .bool(true),
            "store": .bool(false)
        ])
        var request = try request(endpoint: "responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "x-session-id")
        do { request.httpBody = try body.data() }
        catch { throw ControlCenterModelError.invalidInput }
        try Task.checkCancellation()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let task = bytes.task
            defer { task.cancel() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw ControlCenterModelError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw ControlCenterModelError.httpStatus(http.statusCode) }
                let contentType = http.mimeType?.lowercased()
                if contentType == "application/json" {
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    return try Self.turn(from: data)
                }
                guard contentType == "text/event-stream" else { throw ControlCenterModelError.invalidResponse }
                var events = ControlCenterServerSentEvents()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard let event = try events.append(byte) else { continue }
                    if event.data == "[DONE]" { throw ControlCenterModelError.incompleteResponse }
                    guard let object = try Self.json(Data(event.data.utf8)).objectValue,
                          let type = object["type"]?.stringValue,
                          event.name.isEmpty || event.name == type else {
                        throw ControlCenterModelError.invalidResponse
                    }
                    switch type {
                    case "response.output_text.delta", "response.refusal.delta":
                        guard let delta = object["delta"]?.stringValue else { throw ControlCenterModelError.invalidResponse }
                        if !delta.isEmpty { await onTextDelta?(delta) }
                        try Task.checkCancellation()
                    case "response.completed":
                        guard let completed = object["response"],
                              completed.objectValue?["status"]?.stringValue == "completed" else {
                            throw ControlCenterModelError.incompleteResponse
                        }
                        return try Self.turn(from: completed.data())
                    case "response.failed", "error":
                        throw ControlCenterModelError.responseFailed
                    case "response.incomplete":
                        throw ControlCenterModelError.incompleteResponse
                    default:
                        break
                    }
                }
                try Task.checkCancellation()
                throw ControlCenterModelError.incompleteResponse
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? ControlCenterModelError { throw error }
            throw ControlCenterModelError.transport((error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
        }
    }

    private func request(endpoint: String) throws -> URLRequest {
        guard let components = URLComponents(string: connection.baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let baseURL = components.url else {
            throw ControlCenterModelError.invalidBaseURL
        }
        guard !connection.apiKey.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ControlCenterModelError.invalidAPIKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !connection.apiKey.isEmpty {
            request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ControlCenterModelError.transport((error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ControlCenterModelError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ControlCenterModelError.httpStatus(http.statusCode) }
        return data
    }

    private static func json(_ data: Data) throws -> ControlCenterJSON {
        do { return try ControlCenterJSON.decode(data) }
        catch { throw ControlCenterModelError.invalidResponse }
    }

    private static func turn(from data: Data) throws -> ControlCenterModelTurn {
        guard let object = try json(data).objectValue else { throw ControlCenterModelError.invalidResponse }
        if let error = object["error"], error != .null { throw ControlCenterModelError.responseFailed }
        guard let status = object["status"]?.stringValue else { throw ControlCenterModelError.invalidResponse }
        guard status == "completed" else {
            throw status == "failed" ? ControlCenterModelError.responseFailed : ControlCenterModelError.incompleteResponse
        }
        if let details = object["incomplete_details"], details != .null { throw ControlCenterModelError.incompleteResponse }
        guard let output = object["output"]?.arrayValue else { throw ControlCenterModelError.invalidResponse }
        var text: [String] = []
        var calls: [ControlCenterToolCall] = []
        var callIDs: Set<String> = []
        for item in output {
            guard let item = item.objectValue, let type = item["type"]?.stringValue else {
                throw ControlCenterModelError.invalidResponse
            }
            if let status = item["status"]?.stringValue, status != "completed" {
                throw ControlCenterModelError.incompleteResponse
            }
            if type == "function_call" {
                guard let id = item["call_id"]?.stringValue, !id.isEmpty,
                      callIDs.insert(id).inserted,
                      let name = item["name"]?.stringValue, !name.isEmpty,
                      let raw = item["arguments"]?.stringValue else {
                    throw ControlCenterModelError.invalidToolArguments
                }
                let arguments: ControlCenterJSON
                do { arguments = try ControlCenterJSON.decode(Data(raw.utf8)) }
                catch { throw ControlCenterModelError.invalidToolArguments }
                guard arguments.objectValue != nil else { throw ControlCenterModelError.invalidToolArguments }
                calls.append(ControlCenterToolCall(id: id, name: name, arguments: arguments))
            } else if type == "message" {
                guard let content = item["content"]?.arrayValue else { throw ControlCenterModelError.invalidResponse }
                for part in content {
                    if part.objectValue?["type"]?.stringValue == "output_text",
                       let value = part.objectValue?["text"]?.stringValue {
                        text.append(value)
                    } else if part.objectValue?["type"]?.stringValue == "refusal",
                              let value = part.objectValue?["refusal"]?.stringValue {
                        text.append(value)
                    }
                }
            }
        }
        return ControlCenterModelTurn(output: output, text: text.joined(separator: "\n"), calls: calls)
    }
}

private struct ControlCenterServerSentEvents {
    struct Event {
        let name: String
        let data: String
    }

    private var line = Data()
    private var name = ""
    private var data: [String] = []
    private var previousWasCR = false
    private var isFirstLine = true

    mutating func append(_ byte: UInt8) throws -> Event? {
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else {
            line.append(byte)
            return nil
        }
        previousWasCR = byte == 13
        guard var value = String(data: line, encoding: .utf8) else { throw ControlCenterModelError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if value.first == "\u{FEFF}" { value.removeFirst() }
        }
        if value.isEmpty {
            defer {
                name = ""
                data.removeAll(keepingCapacity: true)
            }
            return data.isEmpty ? nil : Event(name: name, data: data.joined(separator: "\n"))
        }
        if value.first == ":" { return nil }
        let colon = value.firstIndex(of: ":") ?? value.endIndex
        let field = value[..<colon]
        var content = colon == value.endIndex ? value[value.endIndex...] : value[value.index(after: colon)...]
        if content.first == " " { content.removeFirst() }
        if field == "event" { name = String(content) }
        if field == "data" { data.append(String(content)) }
        return nil
    }
}

private final class ControlCenterHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let disposition: URLSession.AuthChallengeDisposition = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge
        completionHandler(disposition, nil)
    }
}
