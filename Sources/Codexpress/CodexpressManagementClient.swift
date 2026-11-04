import CFNetwork
import Darwin
import Foundation

/// Reads the native app's private control settings anew for every fixed-route request.
actor CodexpressManagementClient: CodexpressManagementServing {
    private struct Configuration: Decodable, Sendable {
        let enabled: Bool
        let port: UInt16
        let key: String
    }

    private struct Payload: Encodable {
        var sourceID: String?
        var id: String?
        var requestID: UUID?
        var includeCredits: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case sourceID = "source_id"
            case requestID = "request_id"
            case includeCredits = "include_credits"
        }
    }

    private let configurationURL: URL
    private let session: URLSession
    private let configurationLimit = 16 * 1_024
    private let responseLimit = 8 * 1_024 * 1_024

    init(configurationURL: URL) {
        self.configurationURL = configurationURL
        let policy = URLSessionConfiguration.ephemeral
        policy.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
        policy.httpCookieStorage = nil
        policy.httpShouldSetCookies = false
        policy.httpCookieAcceptPolicy = .never
        policy.urlCredentialStorage = nil
        policy.urlCache = nil
        policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        policy.waitsForConnectivity = false
        policy.timeoutIntervalForRequest = 15
        policy.timeoutIntervalForResource = 20
        policy.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: policy, delegate: CodexpressSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func status() async throws -> CodexpressSnapshot {
        try await request(path: "/v1/status", body: nil, as: CodexpressSnapshot.self)
    }

    func perform(_ action: CodexpressManagementAction) async throws -> CodexpressOperation {
        let path: String
        let payload: Payload
        switch action {
        case .takeover(let sourceID):
            path = "/v1/routing/takeover"
            payload = Payload(sourceID: sourceID)
        case .cancelTakeover(let id):
            path = "/v1/routing/cancel"
            payload = Payload(id: id)
        case .recover(let sourceID):
            path = "/v1/routing/recover"
            payload = Payload(sourceID: sourceID)
        case .refreshBalance(let sourceID):
            path = "/v1/refresh/balances"
            payload = Payload(sourceID: sourceID)
        case .refreshQuota(let sourceID):
            path = "/v1/refresh/quotas"
            payload = Payload(sourceID: sourceID, includeCredits: true)
        case .requestReset(let sourceID, let requestID):
            path = "/v1/credits/reset-requests"
            payload = Payload(sourceID: sourceID, requestID: requestID)
        }
        let body = try JSONEncoder().encode(payload)
        guard body.count <= 64 * 1_024 else {
            throw CodexpressManagementError.invalidConfiguration
        }
        if case .requestReset(let sourceID, let requestID) = action {
            let reset = try await request(path: path, body: body, as: CodexpressResetRequest.self)
            guard UUID(uuidString: reset.id) == requestID, reset.sourceID == sourceID else {
                throw CodexpressManagementError.outcomeUnknown
            }
            return CodexpressOperation(id: reset.id, status: reset.status, result: nil)
        }
        let operation = try await request(path: path, body: body, as: CodexpressOperation.self)
        switch action {
        case .refreshBalance, .refreshQuota:
            guard let id = operation.id, UUID(uuidString: id) != nil, operation.status != nil else {
                throw CodexpressManagementError.outcomeUnknown
            }
        case .takeover:
            guard let id = operation.id, !id.isEmpty else {
                throw CodexpressManagementError.outcomeUnknown
            }
        case .cancelTakeover, .recover, .requestReset:
            break
        }
        return operation
    }

    func operation(id: String) async throws -> CodexpressOperation {
        guard let uuid = UUID(uuidString: id) else {
            throw CodexpressManagementError.invalidResponse
        }
        let operation = try await request(
            path: "/v1/operations/\(uuid.uuidString.lowercased())",
            body: nil,
            as: CodexpressOperation.self
        )
        guard let returnedID = operation.id, UUID(uuidString: returnedID) == uuid,
              operation.status != nil else {
            throw CodexpressManagementError.invalidResponse
        }
        return operation
    }

    func resetRequest(id: UUID) async throws -> CodexpressResetRequest {
        let reset = try await request(
            path: "/v1/credits/reset-requests/\(id.uuidString.lowercased())",
            body: nil,
            as: CodexpressResetRequest.self
        )
        guard UUID(uuidString: reset.id) == id else {
            throw CodexpressManagementError.invalidResponse
        }
        return reset
    }

    private func request<Response: Decodable & Sendable>(
        path: String,
        body: Data?,
        as type: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        let settings = try readConfiguration()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(settings.port)
        components.path = path
        guard let url = components.url else { throw CodexpressManagementError.invalidConfiguration }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(settings.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            // The delegate refuses a replacement stream, so submitted POST bodies cannot be replayed.
            request.httpBodyStream = InputStream(data: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        try Task.checkCancellation()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else {
                throw CodexpressManagementError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexpressManagementError.unauthorized
            }
            guard (200...299).contains(http.statusCode) else {
                throw CodexpressManagementError.httpStatus(http.statusCode)
            }
            guard http.mimeType?.lowercased() == "application/json",
                  response.expectedContentLength <= Int64(responseLimit) else {
                throw CodexpressManagementError.invalidResponse
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < responseLimit else { throw CodexpressManagementError.invalidResponse }
                data.append(byte)
            }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            if body != nil {
                if let error = error as? CodexpressManagementError, error.isDefiniteRejection {
                    throw error
                }
                throw CodexpressManagementError.outcomeUnknown
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? CodexpressManagementError { throw error }
            if error is DecodingError { throw CodexpressManagementError.invalidResponse }
            throw CodexpressManagementError.unavailable
        }
    }

    private func readConfiguration() throws -> Configuration {
        let path = configurationURL.path
        guard configurationURL.isFileURL,
              configurationURL.host == nil || configurationURL.host == "" || configurationURL.host == "localhost",
              configurationURL.query == nil, configurationURL.fragment == nil,
              path.hasPrefix("/"), !path.utf8.contains(0),
              configurationURL.lastPathComponent == "control-access.json" else {
            throw CodexpressManagementError.invalidConfiguration
        }
        let parts = path.split(separator: "/")
        guard !parts.contains("."), !parts.contains(".."), let name = parts.last else {
            throw CodexpressManagementError.invalidConfiguration
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CodexpressManagementError.unavailable }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = Darwin.openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.configurationReadError(errno) }
            Darwin.close(directory)
            directory = next
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == geteuid(),
              parent.st_mode & mode_t(0o077) == 0 else {
            throw CodexpressManagementError.insecureConfiguration
        }
        try requireNoExtendedACL(directory)
        let descriptor = Darwin.openat(
            directory, String(name), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Self.configurationReadError(errno) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw CodexpressManagementError.unavailable }
        try requirePrivateFile(before)
        try requireNoExtendedACL(descriptor)
        guard before.st_size > 0, before.st_size <= Int64(configurationLimit) else {
            throw CodexpressManagementError.invalidConfiguration
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if received < 0, errno == EINTR { continue }
            guard received >= 0 else { throw CodexpressManagementError.unavailable }
            if received == 0 { break }
            count += received
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw CodexpressManagementError.unavailable }
        try requirePrivateFile(after)
        try requireNoExtendedACL(descriptor)
        guard count == Int(before.st_size), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CodexpressManagementError.invalidConfiguration
        }
        guard let settings = try? JSONDecoder().decode(Configuration.self, from: Data(bytes.prefix(count))),
              settings.port > 0, (16...256).contains(settings.key.utf8.count),
              settings.key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw CodexpressManagementError.invalidConfiguration
        }
        guard settings.enabled else { throw CodexpressManagementError.disabled }
        return settings
    }

    private func requirePrivateFile(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_nlink == 1, metadata.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw CodexpressManagementError.insecureConfiguration
        }
    }

    /// Mode bits alone do not exclude an ACL granting another account access.
    private func requireNoExtendedACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports an absent extended ACL as ENOENT, not an empty list.
            guard errno == ENOENT else { throw CodexpressManagementError.insecureConfiguration }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0,
              acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else {
            throw CodexpressManagementError.insecureConfiguration
        }
    }

    private static func configurationReadError(_ code: Int32) -> CodexpressManagementError {
        switch code {
        case ENOENT: return .notConfigured
        case ELOOP, ENOTDIR, EACCES, EPERM: return .insecureConfiguration
        default: return .unavailable
        }
    }
}
