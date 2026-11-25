import CFNetwork
import Darwin
import Foundation

/// Reads the selected loopback credentials anew for every fixed-route request.
actor CodexpressManagementClient: CodexpressManagementServing {
    enum ConnectionSelection: Sendable {
        case automatic
        case manual(port: Int, key: String)
    }

    private struct Configuration: Decodable, Sendable, Equatable {
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
    private let connectionSelection: @Sendable () async throws -> ConnectionSelection
    private var activeConfiguration: Configuration?
    private var authorizedGateway: CodexpressGateway?
    private var cachedPublication: (revision: CodexpressGateway.Revision, value: CodexpressGateway)?
    private var permitsLegacyAbsence = true
    private let session: URLSession
    private let configurationLimit = 16 * 1_024
    private let responseLimit = 8 * 1_024 * 1_024

    init(
        configurationURL: URL,
        connectionSelection: @escaping @Sendable () async throws -> ConnectionSelection = { .automatic }
    ) {
        self.configurationURL = configurationURL
        self.connectionSelection = connectionSelection
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

    func status(for gateway: CodexpressGateway) async throws -> CodexpressSnapshot {
        try await request(
            gateway: gateway,
            path: "/v1/status",
            queryItems: [URLQueryItem(name: "include_usage", value: "false")],
            body: nil,
            as: CodexpressSnapshot.self
        )
    }

    func perform(_ action: CodexpressManagementAction, for gateway: CodexpressGateway) async throws -> CodexpressOperation {
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
            let reset = try await request(gateway: gateway, path: path, body: body, as: CodexpressResetRequest.self)
            guard UUID(uuidString: reset.id) == requestID, reset.sourceID == sourceID else {
                throw CodexpressManagementError.outcomeUnknown
            }
            return CodexpressOperation(id: reset.id, status: reset.status, result: nil)
        }
        let operation = try await request(gateway: gateway, path: path, body: body, as: CodexpressOperation.self)
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

    func operation(id: String, for gateway: CodexpressGateway) async throws -> CodexpressOperation {
        guard let uuid = UUID(uuidString: id) else {
            throw CodexpressManagementError.invalidResponse
        }
        let operation = try await request(
            gateway: gateway,
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

    func resetRequest(id: UUID, for gateway: CodexpressGateway) async throws -> CodexpressResetRequest {
        let reset = try await request(
            gateway: gateway,
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
        gateway expectedGateway: CodexpressGateway,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data?,
        as type: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        let settings = try await selectedConfiguration(for: expectedGateway)
        let isStatus = path == "/v1/status" && body == nil
        if let activeConfiguration, activeConfiguration != settings {
            self.activeConfiguration = nil
            throw CodexpressManagementError.connectionChanged
        }
        guard isStatus || (activeConfiguration == settings && authorizedGateway == expectedGateway) else {
            throw CodexpressManagementError.connectionChanged
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(settings.port)
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
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
        try requireLocal(expectedGateway)
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
            let decoded = try JSONDecoder().decode(type, from: data)
            let currentSettings: Configuration
            do {
                currentSettings = try await selectedConfiguration(for: expectedGateway)
            } catch where body != nil {
                // The POST was submitted; a changed selection cannot prove it was rejected.
                throw CodexpressManagementError.outcomeUnknown
            }
            guard currentSettings == settings else {
                activeConfiguration = nil
                throw body == nil ? CodexpressManagementError.connectionChanged : CodexpressManagementError.outcomeUnknown
            }
            if isStatus {
                activeConfiguration = settings
                authorizedGateway = expectedGateway
            }
            return decoded
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

    private func requireLocal(_ expected: CodexpressGateway) throws {
        guard expected.isLocal, gateway() == expected else { throw CodexpressManagementError.connectionChanged }
    }

    private func selectedConfiguration(for expected: CodexpressGateway) async throws -> Configuration {
        try requireLocal(expected)
        let selection = try await connectionSelection()
        try requireLocal(expected)
        switch selection {
        case .automatic:
            return try readConfiguration()
        case .manual(let port, let key):
            guard !key.isEmpty else { throw CodexpressManagementError.missingManualKey }
            guard (1...65_535).contains(port), (16...256).contains(key.utf8.count),
                  key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
                throw CodexpressManagementError.invalidConfiguration
            }
            return Configuration(enabled: true, port: UInt16(port), key: key)
        }
    }

    private func readConfiguration() throws -> Configuration {
        guard configurationURL.lastPathComponent == "control-access.json" else {
            throw CodexpressManagementError.invalidConfiguration
        }
        let data = try withPrivateFile(named: "control-access.json") { fd, metadata in
            try readData(fd, metadata: metadata, limit: configurationLimit)
        }
        guard let settings = try? JSONDecoder().decode(Configuration.self, from: data),
              settings.port > 0, (16...256).contains(settings.key.utf8.count),
              settings.key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw CodexpressManagementError.invalidConfiguration
        }
        guard settings.enabled else { throw CodexpressManagementError.disabled }
        return settings
    }

    func gateway() -> CodexpressGateway {
        let value: CodexpressGateway
        do {
            value = try withPrivateFile(named: "cmux-gateway.json") { fd, metadata in
                let revision = CodexpressGateway.Revision(device: metadata.st_dev, inode: metadata.st_ino,
                    seconds: metadata.st_ctimespec.tv_sec, nanoseconds: metadata.st_ctimespec.tv_nsec)
                if let cachedPublication, cachedPublication.revision == revision { return cachedPublication.value }
                let data = try readData(fd, metadata: metadata, limit: responseLimit)
                let publication = try CodexpressGateway(data: data, revision: revision)
                cachedPublication = (revision, publication)
                return publication
            }
            permitsLegacyAbsence = false
        } catch CodexpressManagementError.notConfigured {
            value = permitsLegacyAbsence ? .local(nil) : .unavailable
        } catch {
            permitsLegacyAbsence = false
            value = .unavailable
        }
        if authorizedGateway != value { activeConfiguration = nil; authorizedGateway = nil }
        return value
    }

    // Watch the containing directory: publication uses rename, replacing the previous inode.
    nonisolated func watchGateway(_ changed: @escaping @Sendable (Bool) -> Void) -> (any DispatchSourceFileSystemObject)? {
        guard let fd = try? openStateDirectory() else { return nil }
        let detached: DispatchSource.FileSystemEvent = [.delete, .rename, .revoke]
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .attrib, detached], queue: .main)
        watcher.setEventHandler { changed(!watcher.data.intersection(detached).isEmpty) }
        watcher.setCancelHandler { Darwin.close(fd) }
        watcher.activate()
        return watcher
    }

    private nonisolated func openStateDirectory() throws -> Int32 {
        let directoryURL = configurationURL.deletingLastPathComponent()
        let path = directoryURL.path
        let parts = path.split(separator: "/")
        guard directoryURL.isFileURL, (directoryURL.host ?? "").isEmpty || directoryURL.host == "localhost",
              directoryURL.query == nil, directoryURL.fragment == nil, path.hasPrefix("/"), !path.utf8.contains(0),
              !parts.isEmpty, !parts.contains("."), !parts.contains("..") else {
            throw CodexpressManagementError.invalidConfiguration
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CodexpressManagementError.unavailable }
        for part in parts {
            let next = Darwin.openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let failure = Self.configurationReadError(errno)
                Darwin.close(directory)
                throw failure
            }
            Darwin.close(directory)
            directory = next
        }
        return directory
    }

    private func withPrivateFile<T>(named name: String, _ body: (Int32, stat) throws -> T) throws -> T {
        let directory = try openStateDirectory()
        defer { Darwin.close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == geteuid(),
              parent.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw CodexpressManagementError.insecureConfiguration
        }
        try requireNoExtendedACL(directory)
        let descriptor = Darwin.openat(
            directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Self.configurationReadError(errno) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw CodexpressManagementError.unavailable }
        try requirePrivateFile(before)
        try requireNoExtendedACL(descriptor)
        return try body(descriptor, before)
    }

    private func readData(_ descriptor: Int32, metadata before: stat, limit: Int) throws -> Data {
        guard before.st_size > 0, before.st_size <= Int64(limit) else {
            throw CodexpressManagementError.invalidConfiguration
        }
        var bytes = Data(count: Int(before.st_size))
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
        return bytes
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
