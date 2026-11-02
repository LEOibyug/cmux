import Darwin
import Foundation

/// The global config's filesystem generation, without reading any agent history data.
struct CmuxVaultHistoryConfigurationGeneration: Equatable, Sendable {
    let path: String
    private let resolvedPath: String?
    private let entry: FileState
    private let target: FileState
    private let missingParent: MissingParent?

    var isMissing: Bool {
        entry == .missing
    }

    var isInspectable: Bool {
        entry.isInspectable && target.isInspectable
            && (target == .missing || resolvedPath != nil)
            && (missingParent?.isInspectable ?? true)
    }

    var isCurrent: Bool {
        isInspectable && self == Self.capture(path: path)
    }

    static func capture(path: String) -> Self {
        let entry = FileState.capture(path: path, followingSymlinks: false)
        let target = entry.isSymbolicLink
            ? FileState.capture(path: path, followingSymlinks: true)
            : entry
        let resolvedPath = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX)) { buffer in
            guard let pointer = realpath(path, buffer.baseAddress) else { return nil as String? }
            return String(cString: pointer)
        }
        return Self(
            path: path,
            resolvedPath: resolvedPath,
            entry: entry,
            target: target,
            missingParent: entry == .missing ? MissingParent.capture(for: path) : nil
        )
    }

    /// Directory metadata prevents an absent config's generation reviving after creation and removal.
    private struct MissingParent: Equatable, Sendable {
        let path: String
        let entry: FileState
        let target: FileState

        var isInspectable: Bool {
            entry.isInspectable && target.isDirectory
        }

        static func capture(for path: String) -> Self {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while true {
                let entry = FileState.capture(path: parent.path, followingSymlinks: false)
                let target = entry.isSymbolicLink
                    ? FileState.capture(path: parent.path, followingSymlinks: true)
                    : entry
                if target != .missing || parent.path == "/" {
                    return Self(path: parent.path, entry: entry, target: target)
                }
                parent.deleteLastPathComponent()
            }
        }
    }

    private enum FileState: Equatable, Sendable {
        case missing
        case present(Stamp)
        case unavailable(Int32)

        var isInspectable: Bool {
            if case .unavailable = self { return false }
            return true
        }

        var isSymbolicLink: Bool {
            guard case .present(let stamp) = self else { return false }
            return stamp.mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        }

        var isDirectory: Bool {
            guard case .present(let stamp) = self else { return false }
            return stamp.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }

        static func capture(path: String, followingSymlinks: Bool) -> Self {
            var status = stat()
            let result = followingSymlinks ? stat(path, &status) : lstat(path, &status)
            guard result == 0 else {
                let error = errno
                return error == ENOENT ? .missing : .unavailable(error)
            }
            return .present(Stamp(
                device: status.st_dev,
                inode: status.st_ino,
                mode: status.st_mode,
                size: status.st_size,
                modificationSeconds: status.st_mtimespec.tv_sec,
                modificationNanoseconds: status.st_mtimespec.tv_nsec,
                changeSeconds: status.st_ctimespec.tv_sec,
                changeNanoseconds: status.st_ctimespec.tv_nsec
            ))
        }
    }

    private struct Stamp: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int
    }
}
