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
        case .invalidInput: return "The model request cannot be encoded as JSON or exceeds the 32 MiB request limit. Start a new conversation or use smaller images."
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
        onEvent: (@Sendable (ControlCenterModelEvent) async -> Void)? = nil
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
                "strict": .bool(false),
                "parameters": tool.parameters
            ])
        }
        var fields: [String: ControlCenterJSON] = [
            "model": .string(connection.model),
            "input": .array(input),
            "tools": .array(toolJSON),
            "stream": .bool(true),
            "store": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if let effort = connection.reasoningEffort {
            fields["reasoning"] = .object(["effort": .string(effort)])
        }
        let body = ControlCenterJSON.object(fields)
        var request = try request(endpoint: "responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "x-session-id")
        do {
            let data = try body.data()
            guard data.count <= 32 * 1024 * 1024 else { throw ControlCenterModelError.invalidInput }
            request.httpBody = data
        }
        catch { throw ControlCenterModelError.invalidInput }
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<ControlCenterHTTPEvent, any Error>.makeStream()
        let transport = URLSession(configuration: session.configuration, delegate: ControlCenterHTTPDelegate(continuation: continuation), delegateQueue: nil)
        let task = transport.dataTask(with: request)
        defer { transport.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await onEvent?(.requestSubmitted(body))
                try Task.checkCancellation()
                task.resume()
                var contentType: String?
                var data = Data()
                var events = ControlCenterServerSentEvents()
                var progress = ControlCenterModelProgress()
                for try await chunk in stream {
                    try Task.checkCancellation()
                    switch chunk {
                    case .response(let response):
                        guard let http = response as? HTTPURLResponse else { throw ControlCenterModelError.invalidResponse }
                        guard (200..<300).contains(http.statusCode) else { throw ControlCenterModelError.httpStatus(http.statusCode) }
                        contentType = http.mimeType?.lowercased()
                        guard contentType == "application/json" || contentType == "text/event-stream" else {
                            throw ControlCenterModelError.invalidResponse
                        }
                        await onEvent?(.responseStarted)
                    case .data(let chunk):
                        if contentType == "application/json" {
                            data.append(chunk)
                            continue
                        }
                        guard contentType == "text/event-stream" else { throw ControlCenterModelError.invalidResponse }
                        for byte in chunk {
                            guard let event = try events.append(byte) else { continue }
                            if event.data == "[DONE]" { throw ControlCenterModelError.incompleteResponse }
                            guard let object = try Self.json(Data(event.data.utf8)).objectValue,
                                  let type = object["type"]?.stringValue,
                                  event.name.isEmpty || event.name == type else {
                                throw ControlCenterModelError.invalidResponse
                            }
                            switch type {
                            case "response.completed":
                                guard let completed = object["response"],
                                      completed.objectValue?["status"]?.stringValue == "completed" else {
                                    throw ControlCenterModelError.incompleteResponse
                                }
                                let turn = try Self.turn(from: completed.data())
                                for event in progress.complete(turn) { await onEvent?(event) }
                                try Task.checkCancellation()
                                return turn
                            case "response.failed", "error":
                                throw ControlCenterModelError.responseFailed
                            case "response.incomplete":
                                throw ControlCenterModelError.incompleteResponse
                            default:
                                if let event = try progress.append(type: type, object: object) { await onEvent?(event) }
                                try Task.checkCancellation()
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                guard contentType == "application/json" else { throw ControlCenterModelError.incompleteResponse }
                let turn = try Self.turn(from: data)
                for event in progress.complete(turn) { await onEvent?(event) }
                try Task.checkCancellation()
                return turn
            } onCancel: {
                transport.invalidateAndCancel()
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

// Progress is provisional. Only turn(from:) validates a complete response for execution.
private struct ControlCenterModelProgress {
    private struct Call: Equatable {
        let id: String
        let name: String
        var arguments: String
    }

    private var emitted: [String: String] = [:]
    private var itemKeys: [String: String] = [:]
    private var calls: [String: Call] = [:]
    private var emittedCalls: [String: Call] = [:]

    mutating func append(type: String, object: [String: ControlCenterJSON]) throws -> ControlCenterModelEvent? {
        switch type {
        case "response.output_text.delta", "response.refusal.delta", "response.reasoning_summary_text.delta":
            guard let delta = object["delta"]?.stringValue else { throw ControlCenterModelError.invalidResponse }
            let reasoning = type == "response.reasoning_summary_text.delta"
            return update(delta, key: contentKey(object, reasoning: reasoning), delta: true, reasoning: reasoning)
        case "response.output_text.done", "response.refusal.done", "response.reasoning_summary_text.done":
            let reasoning = type == "response.reasoning_summary_text.done"
            guard let text = object["text"]?.stringValue ?? object["refusal"]?.stringValue else {
                throw ControlCenterModelError.invalidResponse
            }
            return update(text, key: contentKey(object, reasoning: reasoning), delta: false, reasoning: reasoning)
        case "response.output_item.added", "response.output_item.done":
            guard let item = object["item"]?.objectValue else { throw ControlCenterModelError.invalidResponse }
            let key = itemKey(object) ?? item["id"]?.stringValue
            if let id = item["id"]?.stringValue, let key { itemKeys[id] = key }
            guard item["type"]?.stringValue == "function_call", let key,
                  let id = item["call_id"]?.stringValue, !id.isEmpty,
                  let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
            let call = Call(id: id, name: name, arguments: item["arguments"]?.stringValue ?? "")
            calls[key] = call
            return emit(call)
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            guard let key = itemKey(object), var call = calls[key] else { return nil }
            if type == "response.function_call_arguments.delta" {
                guard let delta = object["delta"]?.stringValue else { throw ControlCenterModelError.invalidResponse }
                call.arguments += delta
            } else {
                guard let arguments = object["arguments"]?.stringValue else { throw ControlCenterModelError.invalidResponse }
                call.arguments = arguments
            }
            calls[key] = call
            return emit(call)
        default:
            return nil
        }
    }

    mutating func complete(_ turn: ControlCenterModelTurn) -> [ControlCenterModelEvent] {
        var events: [ControlCenterModelEvent] = []
        var summary: [String] = []
        let unindexedText = emitted["text|unindexed"] != nil
        let unindexedReasoning = emitted["reasoning|unindexed"] != nil
        for (index, output) in turn.output.enumerated() {
            guard let item = output.objectValue else { continue }
            let key = item["id"]?.stringValue.flatMap { itemKeys[$0] } ?? String(Double(index))
            switch item["type"]?.stringValue {
            case "function_call":
                if let id = item["call_id"]?.stringValue, let name = item["name"]?.stringValue,
                   let arguments = item["arguments"]?.stringValue {
                    if let event = emit(Call(id: id, name: name, arguments: arguments)) { events.append(event) }
                }
            case "message":
                for (partIndex, part) in (item["content"]?.arrayValue ?? []).enumerated() {
                    guard let part = part.objectValue,
                          let text = part["text"]?.stringValue ?? part["refusal"]?.stringValue,
                          part["type"]?.stringValue == "output_text" || part["type"]?.stringValue == "refusal" else { continue }
                    if !unindexedText,
                       let event = update(text, key: "text|\(key)|\(Double(partIndex))", delta: false, reasoning: false) {
                        events.append(event)
                    }
                }
            case "reasoning":
                for (partIndex, part) in (item["summary"]?.arrayValue ?? []).enumerated() {
                    guard part.objectValue?["type"]?.stringValue == "summary_text",
                          let text = part.objectValue?["text"]?.stringValue else { continue }
                    if unindexedReasoning { summary.append(text) }
                    else if let event = update(text, key: "reasoning|\(key)|\(Double(partIndex))", delta: false, reasoning: true) {
                        events.append(event)
                    }
                }
            default:
                break
            }
        }
        if unindexedText, let event = update(turn.text, key: "text|unindexed", delta: false, reasoning: false) {
            events.append(event)
        }
        if unindexedReasoning, let event = update(summary.joined(separator: "\n"), key: "reasoning|unindexed", delta: false, reasoning: true) {
            events.append(event)
        }
        return events
    }

    private func itemKey(_ object: [String: ControlCenterJSON]) -> String? {
        if let index = object["output_index"]?.numberValue { return String(index) }
        if let id = object["item_id"]?.stringValue { return itemKeys[id] ?? id }
        return nil
    }

    private func contentKey(_ object: [String: ControlCenterJSON], reasoning: Bool) -> String {
        let kind = reasoning ? "reasoning" : "text"
        guard let item = itemKey(object) else { return "\(kind)|unindexed" }
        let index = object[reasoning ? "summary_index" : "content_index"]?.numberValue ?? 0
        return "\(kind)|\(item)|\(index)"
    }

    private mutating func update(_ value: String, key: String, delta: Bool, reasoning: Bool) -> ControlCenterModelEvent? {
        let previous = emitted[key] ?? ""
        let addition: String
        if delta {
            addition = value
            emitted[key] = previous + value
        } else {
            // Completed/done payloads repeat deltas. Emit only the unseen suffix.
            guard value.hasPrefix(previous) else { return nil }
            addition = String(value.dropFirst(previous.count))
            emitted[key] = value
        }
        guard !addition.isEmpty else { return nil }
        return reasoning ? .reasoningDelta(addition) : .textDelta(addition)
    }

    private mutating func emit(_ call: Call) -> ControlCenterModelEvent? {
        guard emittedCalls[call.id] != call else { return nil }
        emittedCalls[call.id] = call
        return .toolCall(id: call.id, name: call.name, arguments: call.arguments)
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

private enum ControlCenterHTTPEvent: Sendable {
    case response(URLResponse)
    case data(Data)
}

private final class ControlCenterHTTPDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let continuation: AsyncThrowingStream<ControlCenterHTTPEvent, any Error>.Continuation?

    init(continuation: AsyncThrowingStream<ControlCenterHTTPEvent, any Error>.Continuation? = nil) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        continuation?.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
    }

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
