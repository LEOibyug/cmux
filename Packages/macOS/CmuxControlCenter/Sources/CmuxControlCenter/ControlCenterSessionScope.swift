internal import Foundation
internal import Darwin

public struct ControlCenterSessionScope: Equatable, Sendable {
    public let directory: String
    public let canonicalDirectory: String

    public init(directory: String) throws {
        let expanded = (directory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue,
              let canonicalDirectory = Self.canonicalCwd(expanded) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.directory = url.path
        self.canonicalDirectory = canonicalDirectory
    }

    public func contains(_ cwd: String) -> Bool {
        guard let path = Self.canonicalCwd(cwd) else { return false }
        return path == canonicalDirectory || path.hasPrefix(canonicalDirectory == "/" ? "/" : canonicalDirectory + "/")
    }

    // Resolve the closest existing directory before appending missing historical components.
    // A missing segment followed by '..' must not hide a dangling, escaping or cyclic symlink.
    public static func canonicalCwd(_ cwd: String) -> String? {
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        if let resolved = realpath(cwd, nil) {
            defer { free(resolved) }
            let path = String(cString: resolved)
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        guard errno == ENOENT else { return nil }
        var ancestor = "/"
        var missing: [Substring] = []
        for component in cwd.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !missing.isEmpty {
                    missing.removeLast()
                } else if ancestor != "/" {
                    ancestor = (ancestor as NSString).deletingLastPathComponent
                }
                continue
            }
            if !missing.isEmpty {
                missing.append(component)
                continue
            }
            let candidate = (ancestor == "/" ? "" : ancestor) + "/" + component
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                guard errno == ENOENT else { return nil }
                missing.append(component)
                continue
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard let resolved = realpath(candidate, nil) else { return nil }
                defer { free(resolved) }
                ancestor = String(cString: resolved)
                guard stat(ancestor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
                ancestor = candidate
            }
        }
        let canonical = URL(fileURLWithPath: ancestor).resolvingSymlinksInPath().path
        guard !missing.isEmpty else { return canonical }
        return (canonical == "/" ? "" : canonical) + "/" + missing.joined(separator: "/")
    }
}
