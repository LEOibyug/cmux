import Darwin
import Foundation
import Testing
import CmuxControlCenter

@Suite("Codexpress read-only Unix protocol")
struct ControlCenterCodexpressBindingTests {
    @Test func importsCurrentClientKeyAndDerivesLoopbackAddress() async throws {
        try await CodexpressUnixFixture.withServer(replies: [
            .init(data: #"{"enabled":true,"running":true,"port":21987,"key_set":true,"base_url":"https://untrusted.invalid/v1","listen_address":"0.0.0.0"}"#),
            .init(data: #"{"key":"synthetic-client-key-21987"}"#)
        ]) { server in
            let binding = try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory)
            #expect(binding.baseURL == "http://127.0.0.1:21987/v1")
            #expect(binding.apiKey == "synthetic-client-key-21987")
            #expect(server.requests == ["chatbot.status", "chatbot.key"])
        }
    }

    @Test func invalidIngressNeverRequestsAKey() async throws {
        let cases: [(String, ControlCenterCodexpressError)] = [
            (#"{"enabled":false,"running":true,"port":21987,"key_set":true}"#, .ingressNotRunning),
            (#"{"enabled":true,"running":false,"port":21987,"key_set":true}"#, .ingressNotRunning),
            (#"{"enabled":true,"running":true,"port":0,"key_set":true}"#, .invalidPort),
            (#"{"enabled":true,"running":true,"port":65536,"key_set":true}"#, .invalidResponse),
            (#"{"enabled":true,"running":true,"port":21987,"key_set":false}"#, .invalidKey)
        ]
        for (status, expected) in cases {
            try await CodexpressUnixFixture.withServer(replies: [.init(data: status)]) { server in
                await #expect(throws: expected) {
                    try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory)
                }
                #expect(server.requests == ["chatbot.status"])
            }
        }
    }

    @Test(arguments: [CodexpressUnixFixture.Frame.wrongID, .unterminated, .multiple, .oversized])
    private func rejectsInvalidResponseIdentityAndFraming(_ frame: CodexpressUnixFixture.Frame) async throws {
        try await CodexpressUnixFixture.withServer(replies: [.init(data: CodexpressUnixFixture.status, frame: frame)]) { server in
            await #expect(throws: ControlCenterCodexpressError.invalidResponse) {
                try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory)
            }
            #expect(server.requests.count == 1)
        }
    }

    @Test(arguments: [String(repeating: "a", count: 15), String(repeating: "a", count: 257), "synthetic key with spaces", "synthetic-key-中中中", "synthetic-key-\n-invalid"])
    func rejectsInvalidClientKeysWithoutEchoingThem(_ key: String) async throws {
        let json = String(decoding: try JSONEncoder().encode(["key": key]), as: UTF8.self)
        try await CodexpressUnixFixture.withServer(replies: [.init(data: CodexpressUnixFixture.status), .init(data: json)]) { server in
            do {
                _ = try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory)
                Issue.record("Invalid client key was accepted")
            } catch {
                #expect(error as? ControlCenterCodexpressError == .invalidKey)
                #expect(!error.localizedDescription.contains(key))
            }
            #expect(server.requests == ["chatbot.status", "chatbot.key"])
        }
    }

    @Test func rejectedRequestDoesNotExposeServerErrorOrRetry() async throws {
        try await CodexpressUnixFixture.withServer(replies: [.init(data: "null", frame: .rejected)]) { server in
            do {
                _ = try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory)
                Issue.record("Rejected request was accepted")
            } catch {
                #expect(error as? ControlCenterCodexpressError == .rejected)
                #expect(!error.localizedDescription.contains("synthetic-private-server-error"))
            }
            #expect(server.requests.count == 1)
        }
    }

    @Test func stalledResponseTimesOutAndCancellationInterruptsRead() async throws {
        try await CodexpressUnixFixture.withServer(replies: [.init(data: "null", frame: .hold)]) { server in
            await #expect(throws: ControlCenterCodexpressError.timedOut) {
                try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory, timeout: .milliseconds(120))
            }
            #expect(server.requests.count == 1)
        }
        try await CodexpressUnixFixture.withServer(replies: [.init(data: "null", frame: .hold)]) { server in
            let task = Task { try await ControlCenterCodexpressBinding.current(stateDirectory: server.directory) }
            try await server.waitForRequest()
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(server.requests.count == 1)
        }
    }
}

private final class CodexpressUnixFixture: @unchecked Sendable {
    enum Frame: Sendable { case normal, wrongID, unterminated, multiple, oversized, rejected, hold }
    struct Reply: Sendable {
        let data: String
        var frame: Frame = .normal
    }
    enum FixtureError: Error { case socket, request, timedOut }
    static let status = #"{"enabled":true,"running":true,"port":21987,"key_set":true}"#
    let directory: URL
    private let listener: Int32
    private let lock = NSLock()
    private var captured: [String] = []
    var requests: [String] { lock.withLock { captured } }

    private init() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        directory = root.appendingPathComponent("tmp/cx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw FixtureError.socket
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = directory.appendingPathComponent("control.sock").path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
            throw FixtureError.socket
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 4) == 0 else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
            throw FixtureError.socket
        }
    }

    static func withServer(replies: [Reply], body: (CodexpressUnixFixture) async throws -> Void) async throws {
        let fixture = try Self()
        let task = Task.detached { try fixture.serve(replies) }
        do {
            try await body(fixture)
            task.cancel()
            do { try await task.value } catch is CancellationError {}
            fixture.close()
        } catch {
            task.cancel()
            _ = try? await task.value
            fixture.close()
            throw error
        }
    }

    func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while requests.isEmpty {
            guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func close() {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve(_ replies: [Reply]) throws {
        for reply in replies {
            try wait(listener, events: Int16(POLLIN))
            let peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { throw FixtureError.socket }
            defer { Darwin.close(peer) }
            var noSignal: Int32 = 1
            guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw FixtureError.socket
            }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while request.last != 10 {
                try wait(peer, events: Int16(POLLIN))
                let count = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
                guard count > 0, request.count + count <= 4096 else { throw FixtureError.request }
                request.append(contentsOf: buffer.prefix(count))
            }
            guard let json = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let id = json["id"] as? String, let operation = json["op"] as? String else {
                throw FixtureError.request
            }
            lock.withLock { captured.append(operation) }
            if reply.frame == .hold {
                while true {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let responseID = reply.frame == .wrongID ? UUID().uuidString : id
            let encodedID = String(decoding: try JSONEncoder().encode(responseID), as: UTF8.self)
            var text = "{\"id\":\(encodedID),\"ok\":\(reply.frame != .rejected),\"data\":\(reply.data),\"error\":\"synthetic-private-server-error\"}"
            if reply.frame != .unterminated { text += "\n" }
            if reply.frame == .multiple { text += "{}\n" }
            if reply.frame == .oversized { text = String(repeating: "x", count: 65_537) + "\n" }
            let response = Data(text.utf8)
            try response.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(peer, events: Int16(POLLOUT))
                    let count = Darwin.write(peer, bytes.baseAddress!.advanced(by: offset), min(17, bytes.count - offset))
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EPIPE || errno == ECONNRESET { break }
                    guard count > 0 else { throw FixtureError.socket }
                    offset += count
                }
            }
        }
    }

    private func wait(_ descriptor: Int32, events: Int16) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&readiness, 1, 10)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw FixtureError.socket }
            if result > 0 { return }
        }
    }
}
