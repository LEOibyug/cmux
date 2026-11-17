public import Foundation
internal import CryptoKit
internal import Darwin

public struct ControlCenterFileRead: Codable, Sendable {
    public let path: String
    public let text: String
    public let encoding: String
    public let sha256: String
    public let size: Int
    public let offset: Int
    public let nextOffset: Int?
    public let truncated: Bool
}

public struct ControlCenterFilePlan: Sendable {
    public let requestedPath: String
    public let path: String
    public let operation: String
    public let previousSHA256: String?
    public let newSHA256: String
    public let size: Int
    public let preview: String
    fileprivate let bytes: Data
    fileprivate let binding: FileBinding
    fileprivate let original: FileSnapshot?
}

public struct ControlCenterFileResult: Codable, Sendable {
    public let path: String
    public let operation: String
    public let previousSHA256: String?
    public let sha256: String
    public let size: Int
    public let backupPath: String?
}

public enum ControlCenterFileError: Error, LocalizedError, Sendable {
    case invalidPath
    case invalidRange
    case invalidEncoding
    case invalidEdit(String)
    case conflict(String)
    case notRegularFile(String)
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "A nonempty local file path without NUL bytes is required."
        case .invalidRange: return "File offsets must be nonnegative and limits must be positive; both count bytes."
        case .invalidEncoding: return "Content must use utf8 or valid base64 encoding."
        case .invalidEdit(let reason): return reason
        case .conflict(let path): return "File conflict: \(path) changed since planning or does not match the expected SHA-256. No file was overwritten."
        case .notRegularFile(let path): return "Not a regular file: \(path)."
        case .systemCall(let operation, let code): return "\(operation): \(String(cString: strerror(code))) (\(code))."
        }
    }
}

public enum ControlCenterFiles {
    // Serializes this runtime's own publications; OS file coordination also covers cooperating applications.
    private static let publicationLock = NSLock()
    private static let outputBytes = 36_000

    /// Offset and limit count original bytes. A non-UTF-8 slice is losslessly returned as base64.
    public static func read(path: String, offset: Int = 0, limit: Int = 12_000) throws -> ControlCenterFileRead {
        guard offset >= 0, limit > 0 else { throw ControlCenterFileError.invalidRange }
        let binding = try resolve(path)
        let descriptor = try openFile(binding.path)
        defer { close(descriptor) }
        let captured = try capture(descriptor, offset: offset, limit: min(limit, outputBytes))
        guard try resolve(binding.requestedPath) == binding else { throw ControlCenterFileError.conflict(binding.requestedPath) }
        let representation = represent(captured.data)
        let end = offset + captured.data.count
        return ControlCenterFileRead(
            path: binding.path, text: representation.text, encoding: representation.encoding,
            sha256: captured.snapshot.sha256, size: captured.snapshot.stamp.size, offset: offset,
            nextOffset: end < captured.snapshot.stamp.size ? end : nil,
            truncated: offset > 0 || end < captured.snapshot.stamp.size
        )
    }

    public static func planWrite(path: String, content: String, encoding: String = "utf8", expectedSHA256: String? = nil) throws -> ControlCenterFilePlan {
        let bytes: Data
        switch encoding {
        case "utf8": bytes = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else { throw ControlCenterFileError.invalidEncoding }
            bytes = decoded
        default: throw ControlCenterFileError.invalidEncoding
        }
        let binding = try resolve(path)
        let original = try existing(binding.path, limit: 3_000)
        try checkExpected(expectedSHA256, original?.snapshot, path: binding.path)
        return makePlan(binding: binding, operation: "write", bytes: bytes, original: original)
    }

    public static func planEdit(path: String, oldText: String, newText: String, replaceAll: Bool = false, expectedSHA256: String? = nil) throws -> ControlCenterFilePlan {
        guard !oldText.isEmpty else { throw ControlCenterFileError.invalidEdit("oldText must not be empty.") }
        let binding = try resolve(path)
        guard let original = try existing(binding.path, limit: nil) else { throw ControlCenterFileError.invalidEdit("Cannot edit a missing file: \(binding.path).") }
        try checkExpected(expectedSHA256, original.snapshot, path: binding.path)
        guard String(data: original.data, encoding: .utf8) != nil else { throw ControlCenterFileError.invalidEdit("Text edits require valid UTF-8; use base64 write for binary data.") }
        // Search raw UTF-8: Swift String equality treats canonically equivalent spellings as equal.
        let needle = Data(oldText.utf8)
        guard let first = original.data.range(of: needle) else { throw ControlCenterFileError.invalidEdit("oldText was not found exactly.") }
        if !replaceAll, original.data.range(of: needle, in: (first.lowerBound + 1)..<original.data.endIndex) != nil {
            throw ControlCenterFileError.invalidEdit("oldText matches more than once; provide unique text or replaceAll.")
        }
        var bytes = Data()
        bytes.reserveCapacity(original.data.count)
        let replacement = Data(newText.utf8)
        var cursor = original.data.startIndex
        var match: Range<Data.Index>? = first
        while let range = match {
            bytes.append(original.data[cursor..<range.lowerBound])
            bytes.append(replacement)
            cursor = range.upperBound
            match = replaceAll ? original.data.range(of: needle, in: cursor..<original.data.endIndex) : nil
        }
        bytes.append(original.data[cursor..<original.data.endIndex])
        return makePlan(binding: binding, operation: "edit", bytes: bytes, original: original)
    }

    public static func apply(_ plan: ControlCenterFilePlan, backupRoot: URL) throws -> ControlCenterFileResult {
        try Task.checkCancellation()
        publicationLock.lock()
        defer { publicationLock.unlock() }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<ControlCenterFileResult, any Error>?
        coordinator.coordinate(writingItemAt: URL(fileURLWithPath: plan.path), options: .forReplacing, error: &coordinationError) { _ in
            result = Result { try publish(plan, backupRoot: backupRoot) }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    }

    private static func publish(_ plan: ControlCenterFilePlan, backupRoot: URL) throws -> ControlCenterFileResult {
        try Task.checkCancellation()
        try recheckBinding(plan)
        let target = URL(fileURLWithPath: plan.path)
        let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw failure("Opening target directory") }
        defer { close(parent) }
        guard try stamp(parent).identity == plan.binding.parent else { throw ControlCenterFileError.conflict(plan.requestedPath) }
        let name = target.lastPathComponent
        let originalFD = try checkedOriginal(plan, parent: parent, name: name)
        defer { if let originalFD { close(originalFD) } }

        let temporaryName = ".cmux-file-\(UUID().uuidString)"
        let temporaryFD = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard temporaryFD >= 0 else { throw failure("Creating replacement file") }
        defer { close(temporaryFD); unlinkat(parent, temporaryName, 0) }
        try writeAll(plan.bytes, to: temporaryFD)
        if let originalFD {
            guard fcopyfile(originalFD, temporaryFD, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
                throw failure("Preserving file metadata")
            }
        }
        guard fsync(temporaryFD) == 0 else { throw failure("Persisting replacement file") }

        // Complete and persist the original before publishing any replacement.
        let backup = try originalFD.map { try saveBackup(plan, descriptor: $0, root: backupRoot) }
        try recheckBinding(plan)
        let finalFD = try checkedOriginal(plan, parent: parent, name: name)
        if let finalFD { close(finalFD) }
        try Task.checkCancellation()
        if plan.original == nil {
            // RENAME_EXCL is the atomic non-overwrite guard, including a concurrently created symlink.
            guard renameatx_np(parent, temporaryName, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ControlCenterFileError.conflict(plan.path) }
                throw failure("Publishing new file")
            }
        } else {
            guard renameat(parent, temporaryName, parent, name) == 0 else { throw failure("Publishing replacement file") }
        }
        // The file itself was synced before publication; sync the directory for its new entry.
        _ = fsync(parent)
        return ControlCenterFileResult(path: plan.path, operation: plan.operation, previousSHA256: plan.previousSHA256,
                                       sha256: plan.newSHA256, size: plan.size, backupPath: backup)
    }

    private static func checkedOriginal(_ plan: ControlCenterFilePlan, parent: Int32, name: String) throws -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT, plan.original == nil { return nil }
            if errno == ENOENT || errno == ELOOP { throw ControlCenterFileError.conflict(plan.path) }
            throw failure("Opening original file")
        }
        do {
            let current = try capture(fd, offset: 0, limit: 0).snapshot
            guard current == plan.original else { throw ControlCenterFileError.conflict(plan.path) }
            return fd
        } catch { close(fd); throw error }
    }

    private static func recheckBinding(_ plan: ControlCenterFilePlan) throws {
        guard try resolve(plan.requestedPath) == plan.binding else { throw ControlCenterFileError.conflict(plan.requestedPath) }
    }

    private static func saveBackup(_ plan: ControlCenterFilePlan, descriptor: Int32, root: URL) throws -> String {
        guard root.isFileURL, !root.path.utf8.contains(0) else { throw ControlCenterFileError.invalidPath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw failure("Opening private backup directory") }
        defer { close(rootFD) }
        let rootStamp = try stamp(rootFD)
        guard rootStamp.owner == getuid() else { throw ControlCenterFileError.systemCall("Backup directory is not owned by the current user", EPERM) }
        guard fchmod(rootFD, 0o700) == 0 else { throw failure("Protecting backup directory") }
        let identifier = UUID().uuidString
        guard mkdirat(rootFD, identifier, 0o700) == 0 else { throw failure("Creating private backup") }
        let folder = openat(rootFD, identifier, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure("Opening private backup") }
        defer { close(folder) }
        let fd = openat(folder, "original", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw failure("Creating original-byte backup") }
        defer { close(fd) }
        guard lseek(descriptor, 0, SEEK_SET) >= 0,
              fcopyfile(descriptor, fd, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw failure("Backing up original file and metadata") }
        guard try capture(fd, offset: 0, limit: 0).snapshot.sha256 == plan.previousSHA256 else { throw ControlCenterFileError.conflict(plan.path) }
        guard fsync(fd) == 0 else { throw failure("Persisting original-byte backup") }
        let metadata = BackupMetadata(requestedPath: plan.requestedPath, path: plan.path, sha256: plan.previousSHA256!, original: plan.original!.stamp)
        let metadataFD = openat(folder, "metadata.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard metadataFD >= 0 else { throw failure("Creating backup metadata") }
        defer { close(metadataFD) }
        try writeAll(JSONEncoder().encode(metadata), to: metadataFD)
        guard fsync(metadataFD) == 0, fsync(folder) == 0, fsync(rootFD) == 0 else { throw failure("Persisting backup metadata") }
        return root.appendingPathComponent(identifier).appendingPathComponent("original").path
    }

    private static func makePlan(binding: FileBinding, operation: String, bytes: Data, original: CapturedFile?) -> ControlCenterFilePlan {
        let before = original.map { represent(Data($0.data.prefix(3_000))) }
        let after = represent(Data(bytes.prefix(3_000)))
        let preview = "Original (\(before?.encoding ?? "absent"), first 3000 bytes):\n\(before?.text ?? "[new file]")\nReplacement (\(after.encoding), first 3000 bytes):\n\(after.text)"
        return ControlCenterFilePlan(requestedPath: binding.requestedPath, path: binding.path, operation: operation,
                                    previousSHA256: original?.snapshot.sha256, newSHA256: digest(bytes), size: bytes.count,
                                    preview: preview, bytes: bytes, binding: binding, original: original?.snapshot)
    }

    private static func checkExpected(_ expected: String?, _ snapshot: FileSnapshot?, path: String) throws {
        if let expected, expected.lowercased() != snapshot?.sha256 { throw ControlCenterFileError.conflict(path) }
    }

    private static func existing(_ path: String, limit: Int?) throws -> CapturedFile? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw failure("Opening file")
        }
        defer { close(fd) }
        return try capture(fd, offset: 0, limit: limit)
    }

    private static func openFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Opening file") }
        return fd
    }

    private static func capture(_ fd: Int32, offset: Int, limit: Int?) throws -> CapturedFile {
        let before = try stamp(fd)
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw ControlCenterFileError.notRegularFile("file descriptor \(fd)") }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw failure("Seeking file") }
        var hasher = SHA256()
        var selected = Data()
        var position = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw failure("Reading file") }
            if count == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count]))
                let start = offset > position ? min(offset - position, count) : 0
                let remaining = limit.map { max(0, $0 - selected.count) } ?? count
                let end = start + min(remaining, count - start)
                if start < end { selected.append(raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start), count: end - start) }
            }
            position += count
        }
        let after = try stamp(fd)
        guard before == after, position == before.size else { throw ControlCenterFileError.conflict("file being read") }
        return CapturedFile(snapshot: FileSnapshot(stamp: before, sha256: hex(hasher.finalize())), data: selected)
    }

    private static func resolve(_ path: String) throws -> FileBinding {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw ControlCenterFileError.invalidPath }
        let requested = URL(fileURLWithPath: path).path
        let url = URL(fileURLWithPath: requested)
        let parent = try canonical(url.deletingLastPathComponent().path)
        let resolved: String
        if let pointer = realpath(requested, nil) {
            resolved = String(cString: pointer)
            free(pointer)
        } else if errno == ENOENT {
            // Resolve a dangling leaf symlink rather than replacing the link itself.
            var info = stat()
            if lstat(requested, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: requested)
                let destinationURL = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : url.deletingLastPathComponent().appendingPathComponent(destination)
                let nested = try resolveMissingTarget(destinationURL.path, depth: 0)
                resolved = nested
            } else { resolved = URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).path }
        } else { throw failure("Resolving file path") }
        let resolvedParent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        let parentFD = open(resolvedParent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("Opening file parent directory") }
        defer { close(parentFD) }
        return FileBinding(requestedPath: requested, path: resolved, parent: try stamp(parentFD).identity)
    }

    private static func resolveMissingTarget(_ path: String, depth: Int) throws -> String {
        guard depth < 40 else { throw ControlCenterFileError.systemCall("Resolving symbolic link", ELOOP) }
        if let pointer = realpath(path, nil) { defer { free(pointer) }; return String(cString: pointer) }
        guard errno == ENOENT else { throw failure("Resolving symbolic link") }
        let url = URL(fileURLWithPath: path)
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            let next = destination.hasPrefix("/") ? destination : url.deletingLastPathComponent().appendingPathComponent(destination).path
            return try resolveMissingTarget(next, depth: depth + 1)
        }
        return URL(fileURLWithPath: try canonical(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path
    }

    private static func canonical(_ path: String) throws -> String {
        guard let pointer = realpath(path, nil) else { throw failure("Resolving parent directory") }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func stamp(_ fd: Int32) throws -> FileStamp {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw failure("Inspecting file") }
        return FileStamp(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int(value.st_size), mode: UInt32(value.st_mode), owner: value.st_uid, group: value.st_gid,
                         modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                         changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if count < 0 { if errno == EINTR { continue }; throw failure("Writing file") }
                guard count > 0 else { throw ControlCenterFileError.systemCall("Writing file", EIO) }
                position += count
            }
        }
    }

    private static func represent(_ bytes: Data) -> (text: String, encoding: String) {
        if let text = String(data: bytes, encoding: .utf8) { return (text, "utf8") }
        return (bytes.base64EncodedString(), "base64")
    }

    private static func digest(_ bytes: Data) -> String { hex(SHA256.hash(data: bytes)) }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ operation: String) -> ControlCenterFileError { .systemCall(operation, errno) }
}

private struct FileIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
}

private struct FileBinding: Equatable, Sendable {
    let requestedPath: String
    let path: String
    let parent: FileIdentity
}

private struct FileStamp: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

private struct FileSnapshot: Equatable, Sendable {
    let stamp: FileStamp
    let sha256: String
}

private struct CapturedFile {
    let snapshot: FileSnapshot
    let data: Data
}

private struct BackupMetadata: Encodable {
    let requestedPath: String
    let path: String
    let sha256: String
    let original: FileStamp
}
