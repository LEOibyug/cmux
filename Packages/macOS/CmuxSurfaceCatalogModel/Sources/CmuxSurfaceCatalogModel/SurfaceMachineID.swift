import Foundation

/// A machine explicitly controlled by the user: this Mac or an SSH connection.
public enum SurfaceMachineID: Hashable, Codable, Sendable, CustomStringConvertible {
    case local
    case ssh(String)

    public var description: String {
        switch self {
        case .local: return "local"
        case .ssh(let id): return "ssh:" + id
        }
    }

    /// The durable machine identifier, either `local` or `ssh:<connection>`.
    public var rawValue: String { description }
    public var kind: String {
        switch self {
        case .local: return "local"
        case .ssh: return "ssh"
        }
    }

    /// Parses only retained machine identities; removed service identifiers are rejected.
    /// - Parameter rawValue: A local or SSH wire identifier.
    public init?(rawValue: String) {
        if rawValue == "local" {
            self = .local
        } else if rawValue.hasPrefix("ssh:"), rawValue.count > 4 {
            self = .ssh(String(rawValue.dropFirst(4)))
        } else {
            return nil
        }
    }

    public var isLocal: Bool { if case .local = self { return true }; return false }
    public var isSSH: Bool { if case .ssh = self { return true }; return false }
    public var tuiMachineID: String? { isSSH ? rawValue : nil }
}
