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
        #expect(body?["stream"] == .bool(false))
        #expect(body?["tools"]?.arrayValue?.first?.objectValue?["type"] == .string("function"))
    }

    @Test(arguments: ["not-json", "[]", "null"])
    func malformedToolArgumentsFailTheWholeTurn(_ arguments: String) async throws {
        let response: ControlCenterJSON = .object([
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
        let client = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://127.0.0.1:\(port)/v1", apiKey: secret))
        do {
            _ = try await client.models()
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

    @Test func missingModelAndEmbeddedURLCredentialsFailBeforeTransport() async {
        let missing = ControlCenterModelClient(connection: ControlCenterConnection())
        await #expect(throws: ControlCenterModelError.missingModel) {
            try await missing.respond(input: [], tools: [], operationID: UUID())
        }
        let embedded = ControlCenterModelClient(connection: ControlCenterConnection(baseURL: "http://user:secret@127.0.0.1:1/v1"))
        await #expect(throws: ControlCenterModelError.invalidBaseURL) { try await embedded.models() }
    }
}

private final class ControlCenterHTTPFixture: @unchecked Sendable {
    enum Reply: Sendable {
        case json(Int, String)
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
            guard case .json(let status, let text) = reply else { return }
            let content = Data(text.utf8)
            var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(content)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
