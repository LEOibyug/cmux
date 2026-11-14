import Foundation
import Network
import Testing
import CmuxControlCenter

@Suite("Control Center Responses protocol")
struct ControlCenterModelClientTests {
    @Test func responsesPreserveReasoningAndUseCallIDRatherThanItemID() async throws {
        let server = try ControlCenterHTTPFixture(reply: .json(200, #"""
        {"status":"completed","output":[
          {"type":"reasoning","id":"rs_1","encrypted_content":"opaque-reasoning","summary":[]},
          {"type":"function_call","id":"fc_item","call_id":"call_actual","name":"open_target","arguments":"{\"path\":\"/logical/project\"}"},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Opening the exact target."}]}
        ]}
        """#))
        let port = try await server.start()
        defer { server.stop() }
        let operation = UUID()
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model", apiKey: "test-bearer"))
        let turn = try await client.respond(input: [.object(["role": .string("user"), "content": .string("Open the target")])], tools: [
            ControlCenterTool(name: "open_target", description: "Open a logical target", parameters: .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]))
        ], operationID: operation)
        #expect(turn.calls == [ControlCenterToolCall(id: "call_actual", name: "open_target", arguments: .object(["path": .string("/logical/project")]))])
        #expect(turn.text == "Opening the exact target.")
        #expect(turn.output.first == .object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("opaque-reasoning"), "summary": .array([])]))
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/responses")
        #expect(request.headers["authorization"] == "Bearer test-bearer")
        #expect(request.headers["x-session-id"] == operation.uuidString.lowercased())
        let body = try ControlCenterJSON.decode(request.body).objectValue
        #expect(body?["store"] == .bool(false))
        #expect(body?["stream"] == .bool(true))
        #expect(body?["tools"]?.arrayValue?.first?.objectValue?["type"] == .string("function"))
    }

    @Test(arguments: ["not-json", "[]", "null"])
    func malformedToolArgumentsFailTheWholeTurn(_ arguments: String) async throws {
        let response: ControlCenterJSON = .object([
            "status": .string("completed"),
            "output": .array([
                .object(["type": .string("function_call"), "id": .string("fc_1"), "call_id": .string("call_1"), "name": .string("open_target"), "arguments": .string("{}")]),
                .object(["type": .string("function_call"), "id": .string("fc_2"), "call_id": .string("call_2"), "name": .string("open_target"), "arguments": .string(arguments)])
            ])
        ])
        let server = try ControlCenterHTTPFixture(reply: .json(200, String(decoding: try response.data(), as: UTF8.self)))
        let port = try await server.start()
        defer { server.stop() }
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model"))
        await #expect(throws: ControlCenterModelError.invalidToolArguments) {
            try await client.respond(input: [], tools: [], operationID: UUID())
        }
    }

    @Test func httpFailureDoesNotEchoServerBodyOrCredentialOrRetry() async throws {
        let secret = "do-not-expose-test-token"
        let server = try ControlCenterHTTPFixture(reply: .json(401, "{\"error\":\"Bearer \(secret)\"}"))
        let port = try await server.start()
        defer { server.stop() }
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model", apiKey: secret))
        do {
            _ = try await client.respond(input: [], tools: [], operationID: UUID())
            Issue.record("HTTP 401 must fail")
        } catch {
            #expect(error as? ControlCenterModelError == .httpStatus(401))
            #expect(!error.localizedDescription.contains(secret))
        }
        #expect(server.requests.count == 1)
    }

    @Test func modelsComeFromExplicitServerAndCancellationPropagates() async throws {
        let server = try ControlCenterHTTPFixture(reply: .json(200, "{\"data\":[{\"id\":\"first\"},{\"id\":\"second\"},{\"id\":\"first\"}]}"))
        let port = try await server.start()
        defer { server.stop() }
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1"))
        #expect(try await client.models() == ["first", "second"])
        let held = try ControlCenterHTTPFixture(reply: .hold)
        let heldPort = try await held.start()
        defer { held.stop() }
        let heldClient = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(heldPort)/v1", model: "explicit-model"))
        let task = Task { try await heldClient.respond(input: [], tools: [], operationID: UUID()) }
        try await held.waitForRequest()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(held.requests.count == 1)
    }

    @Test func chunkedEventsDeliverTextBeforeCompletionAndPreserveVerifiedOutput() async throws {
        let prefix = Data(": keepalive\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"Héllo\"}\r\n\r\n".utf8)
        let split = try #require(prefix.firstIndex(of: 0xC3)) + 1
        let terminal = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]},{"type":"function_call","status":"completed","id":"item_1","call_id":"call_1","name":"open_target","arguments":"{\"path\":\"/logical/project\"}"},{"type":"message","status":"completed","content":[{"type":"output_text","text":"Héllo world"}]}]}}"# + "\n\n"
        let server = try ControlCenterHTTPFixture(reply: .stream([
            Data(prefix[..<split]),
            Data(prefix[split...]),
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}\n\ndata: {\"type\":\"response.output_text.done\",\"text\":\"Héllo world\"}\n\n".utf8),
            Data(terminal.utf8)
        ], finish: true))
        let port = try await server.start()
        defer { server.stop() }
        let received = ControlCenterDeltaRecorder()
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model"))
        let turn = try await client.respond(input: [], tools: [], operationID: UUID()) { delta in
            await received.append(delta, beforeFinalChunk: !server.sentFinalStreamChunk)
        }
        let deltas = await received.values
        #expect(deltas == ["Héllo", " world"])
        #expect(await received.allBeforeFinalChunk)
        #expect(turn.text == "Héllo world")
        #expect(turn.calls == [ControlCenterToolCall(id: "call_1", name: "open_target", arguments: .object(["path": .string("/logical/project")]))])
        #expect(turn.output.first?.objectValue?["encrypted_content"] == .string("opaque"))
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [
        ControlCenterStreamFailure(ending: "", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: [DONE]\n\n", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.failed\",\"response\":{\"error\":\"do-not-expose-test-token\"}}\n\n", expected: .responseFailed),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"error\",\"message\":\"do-not-expose-test-token\"}\n\n", expected: .responseFailed),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\",\"output\":[]}}\n\n", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"open_target\",\"arguments\":\"not-json\"}]}}\n\n", expected: .invalidToolArguments),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"status\":\"in_progress\",\"call_id\":\"call_1\",\"name\":\"open_target\",\"arguments\":\"{}\"}]}}\n\n", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}", expected: .incompleteResponse),
        ControlCenterStreamFailure(ending: "data: not-json\n\n", expected: .invalidResponse)
    ])
    func unfinishedOrInvalidStreamsNeverReturnRunnableCalls(_ failure: ControlCenterStreamFailure) async throws {
        let partial = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Visible\"}\n\ndata: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"path\\\":\"}\n\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"open_target\",\"arguments\":\"{}\"}}\n\n"
        let server = try ControlCenterHTTPFixture(reply: .stream([Data(partial.utf8), Data(failure.ending.utf8)], finish: true))
        let port = try await server.start()
        defer { server.stop() }
        let received = ControlCenterDeltaRecorder()
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model", apiKey: "do-not-expose-test-token"))
        do {
            _ = try await client.respond(input: [], tools: [], operationID: UUID()) { delta in
                await received.append(delta)
            }
            Issue.record("An unverified stream must not return a turn or runnable calls")
        } catch let error as ControlCenterModelError {
            #expect(error == failure.expected)
            #expect(!error.localizedDescription.contains("do-not-expose-test-token"))
        }
        #expect(await received.values == ["Visible"])
        #expect(server.requests.count == 1)
    }

    @Test func cancellationInterruptsReceptionAfterPartialText() async throws {
        let server = try ControlCenterHTTPFixture(reply: .stream([
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8)
        ], finish: false))
        let port = try await server.start()
        defer { server.stop() }
        let received = ControlCenterDeltaRecorder()
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model"))
        let task = Task {
            try await client.respond(input: [], tools: [], operationID: UUID()) { delta in
                await received.append(delta)
            }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await received.values.isEmpty {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        #expect(await received.values == ["Partial"])
        #expect(server.requests.count == 1)
    }

    @Test func redirectsNeverForwardAuthorizationOrRetry() async throws {
        let target = try ControlCenterHTTPFixture(reply: .json(200, "{\"status\":\"completed\",\"output\":[]}"))
        let targetPort = try await target.start()
        defer { target.stop() }
        let server = try ControlCenterHTTPFixture(reply: .redirect("http://127.0.0.1:\(targetPort)/stolen"))
        let port = try await server.start()
        defer { server.stop() }
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", model: "explicit-model", apiKey: "do-not-forward"))
        await #expect(throws: ControlCenterModelError.httpStatus(307)) {
            try await client.respond(input: [], tools: [], operationID: UUID())
        }
        #expect(server.requests.count == 1)
        #expect(target.requests.isEmpty)
    }

    @Test func missingModelAndEmbeddedURLCredentialsFailBeforeTransport() async {
        let missing = ControlCenterModelClient(connection: ControlCenterConnection())
        await #expect(throws: ControlCenterModelError.missingModel) {
            try await missing.respond(input: [], tools: [], operationID: UUID())
        }
        let embedded = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://user:secret@127.0.0.1:1/v1"))
        await #expect(throws: ControlCenterModelError.invalidBaseURL) { try await embedded.models() }
    }
}

struct ControlCenterStreamFailure: Sendable {
    let ending: String
    let expected: ControlCenterModelError
}

private actor ControlCenterDeltaRecorder {
    private(set) var values: [String] = []
    private(set) var allBeforeFinalChunk = true

    func append(_ value: String, beforeFinalChunk: Bool = true) {
        values.append(value)
        allBeforeFinalChunk = allBeforeFinalChunk && beforeFinalChunk
    }
}

private final class ControlCenterHTTPFixture: @unchecked Sendable {
    enum Reply: Sendable {
        case json(Int, String)
        case stream([Data], finish: Bool)
        case redirect(String)
        case hold
    }

    struct Request: Sendable {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "control-center-http-tests")
    private let reply: Reply
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private var finalStreamChunk = false
    var sentFinalStreamChunk: Bool { lock.withLock { finalStreamChunk } }
    var requests: [Request] { lock.withLock { captured } }

    init(reply: Reply) throws {
        self.reply = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }
                    continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.isEmpty {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[boundary.upperBound...]
            guard body.count >= length else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                return
            }
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { captured.append(Request(path: path, headers: headers, body: Data(body.prefix(length)))) }
            switch reply {
            case .hold:
                break
            case .json(let status, let text):
                let content = Data(text.utf8)
                var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(content)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            case .redirect(let location):
                let response = Data("HTTP/1.1 307 Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            case .stream(let chunks, let finish):
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { [self] error in
                    if error == nil { sendStream(connection, chunks: chunks, index: 0, finish: finish) }
                })
            }
        }
    }

    private func sendStream(_ connection: NWConnection, chunks: [Data], index: Int, finish: Bool) {
        guard index < chunks.count else {
            if finish {
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
            if index == chunks.count - 1 { lock.withLock { finalStreamChunk = true } }
            let content = chunks[index]
            guard !content.isEmpty else {
                sendStream(connection, chunks: chunks, index: index + 1, finish: finish)
                return
            }
            var chunk = Data("\(String(content.count, radix: 16))\r\n".utf8)
            chunk.append(content)
            chunk.append(Data("\r\n".utf8))
            connection.send(content: chunk, completion: .contentProcessed { [self] error in
                if error == nil { sendStream(connection, chunks: chunks, index: index + 1, finish: finish) }
            })
        }
    }
}
