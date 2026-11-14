public import Foundation
internal import Darwin

public enum ControlCenterCodexpressError: Error, LocalizedError, Equatable, Sendable {
    case invalidStateDirectory
    case unavailable
    case timedOut
    case invalidResponse
    case rejected
    case ingressNotRunning
    case invalidPort
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .invalidStateDirectory: return "The Codexpress state directory cannot be used for its local control socket."
        case .unavailable: return "Cannot reach Codexpress. Open Codexpress and enable its chat ingress, then import again."
        case .timedOut: return "Codexpress did not finish responding in time. No connection settings were changed."
        case .invalidResponse: return "Codexpress returned an invalid local control response. No connection settings were changed."
        case .rejected: return "Codexpress rejected the read-only import request. No connection settings were changed."
        case .ingressNotRunning: return "Enable and start the chat ingress in Codexpress before importing."
        case .invalidPort: return "Codexpress did not report a valid chat ingress port."
        case .invalidKey: return "Codexpress did not report a valid client API key."
        }
    }
}

public struct ControlCenterCodexpressBinding: Sendable {
    public let baseURL: String
    public let apiKey: String

    public static func current(stateDirectory: URL? = nil, timeout: Duration = .seconds(5)) async throws -> Self {
        try Task.checkCancellation()
        let directory: URL
        if let stateDirectory {
            directory = stateDirectory
        } else if let path = ProcessInfo.processInfo.environment["CODEXPRESS_STATE_DIR"] {
            guard !path.isEmpty, !path.utf8.contains(0) else {
                throw ControlCenterCodexpressError.invalidStateDirectory
            }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw ControlCenterCodexpressError.invalidStateDirectory
            }
            directory = support.appendingPathComponent("Codexpress", isDirectory: true)
        }
        guard directory.isFileURL, timeout > .zero else {
            throw ControlCenterCodexpressError.invalidStateDirectory
        }
        let path = directory.appendingPathComponent("control.sock").path
        let task = Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let status: Status = try request("chatbot.status", path: path, deadline: deadline)
            guard status.enabled, status.running else { throw ControlCenterCodexpressError.ingressNotRunning }
            guard status.port > 0 else { throw ControlCenterCodexpressError.invalidPort }
            guard status.key_set else { throw ControlCenterCodexpressError.invalidKey }
            let credential: ClientKey = try request("chatbot.key", path: path, deadline: deadline)
            guard (16...256).contains(credential.key.utf8.count),
                  credential.key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ControlCenterCodexpressError.invalidKey
            }
            try Task.checkCancellation()
            return Self(baseURL: "http://127.0.0.1:\(status.port)/v1", apiKey: credential.key)
        }
        return try await withTaskCancellationHandler {
            let binding = try await task.value
            try Task.checkCancellation()
            return binding
        } onCancel: {
            task.cancel()
        }
    }

    private struct Status: Decodable {
        let enabled: Bool
        let running: Bool
        let port: UInt16
        let key_set: Bool
    }

    private struct ClientKey: Decodable { let key: String }
    private struct Response<Value: Decodable>: Decodable {
        let id: String
        let ok: Bool
        let data: Value?
    }

    private static func request<Value: Decodable>(_ operation: String, path: String, deadline: ContinuousClock.Instant) throws -> Value {
        try Task.checkCancellation()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlCenterCodexpressError.invalidStateDirectory
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlCenterCodexpressError.unavailable }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ControlCenterCodexpressError.unavailable
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw ControlCenterCodexpressError.unavailable }
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                throw ControlCenterCodexpressError.unavailable
            }
        }
        let id = UUID().uuidString
        var outgoing = try ControlCenterJSON.object([
            "id": .string(id), "op": .string(operation), "payload": .object([:])
        ]).data()
        outgoing.append(10)
        try outgoing.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw ControlCenterCodexpressError.unavailable }
                offset += count
            }
        }
        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count >= 0 else { throw ControlCenterCodexpressError.unavailable }
            if count == 0 { break }
            guard incoming.count + count <= 65_536 else { throw ControlCenterCodexpressError.invalidResponse }
            incoming.append(contentsOf: buffer.prefix(count))
            if let newline = incoming.firstIndex(of: 10), newline != incoming.index(before: incoming.endIndex) {
                throw ControlCenterCodexpressError.invalidResponse
            }
        }
        guard incoming.last == 10 else { throw ControlCenterCodexpressError.invalidResponse }
        let response: Response<Value>
        do { response = try JSONDecoder().decode(Response<Value>.self, from: incoming.dropLast()) }
        catch { throw ControlCenterCodexpressError.invalidResponse }
        guard response.id == id else { throw ControlCenterCodexpressError.invalidResponse }
        guard response.ok else { throw ControlCenterCodexpressError.rejected }
        guard let value = response.data else { throw ControlCenterCodexpressError.invalidResponse }
        return value
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ControlCenterCodexpressError.timedOut }
            var ready = pollfd(fd: descriptor, events: events, revents: 0)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = remaining.seconds > 0 ? 50 : max(1, min(50, Int(remaining.attoseconds / 1_000_000_000_000_000)))
            let result = poll(&ready, 1, Int32(milliseconds))
            if result < 0 {
                if errno == EINTR { continue }
                throw ControlCenterCodexpressError.unavailable
            }
            if result > 0 {
                if ready.revents & Int16(POLLNVAL) != 0 { throw ControlCenterCodexpressError.unavailable }
                if ready.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
            }
        }
    }
}
