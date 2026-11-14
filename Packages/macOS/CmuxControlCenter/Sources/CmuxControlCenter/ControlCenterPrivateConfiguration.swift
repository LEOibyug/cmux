internal import Foundation
internal import Darwin

internal enum ControlCenterPrivateConfiguration {
    static func read(_ url: URL) throws -> ControlCenterConnection {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ControlCenterConnection() }
            throw ControlCenterStoreError.privateConfiguration(errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid() else {
            throw ControlCenterStoreError.insecureConfiguration
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ControlCenterStoreError.privateConfiguration(errno)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONDecoder().decode(ControlCenterConnection.self, from: data) }
        catch { throw ControlCenterStoreError.invalidConfiguration }
    }

    static func write(_ connection: ControlCenterConnection, to url: URL) throws {
        let data = try JSONEncoder().encode(connection)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".connection-\(UUID().uuidString).json")
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
        defer {
            Darwin.close(descriptor)
            unlink(temporaryURL.path)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ControlCenterStoreError.privateConfiguration(errno)
                }
                guard count > 0 else { throw ControlCenterStoreError.privateConfiguration(EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
        guard rename(temporaryURL.path, url.path) == 0 else { throw ControlCenterStoreError.privateConfiguration(errno) }
    }
}
