import Foundation

/// Where a notification's text came from, carried with the notification through the
/// store, the hook envelope (`origin`, not hook-patchable), the hook and
/// `notifications.command` environments (`CMUX_NOTIFICATION_ORIGIN`), and the feed
/// history. Remote origins are untrusted emitters: the store clamps their side effects to
/// display (no reply shape, no click action, no agent context, no sound override), and
/// remote-origin notifications never consult project `cmux.json` hooks — only the global
/// config the user wrote on this Mac.
enum TerminalNotificationOrigin: Hashable, Sendable {
    /// A local process (socket caller, OSC from a local PTY, the app itself).
    case local
    /// A `cmux ssh` remote host, confined to the workspace that owns the relay.
    case sshRelay(ownerWorkspaceID: UUID)

    static let localWireValue = "local"
    static let sshRelayWirePrefix = "ssh-relay:"

    /// What hooks see in `CMUX_NOTIFICATION_ORIGIN` and `origin.value`.
    var wireValue: String {
        switch self {
        case .local:
            return Self.localWireValue
        case .sshRelay(let ownerWorkspaceID):
            return Self.sshRelayWirePrefix + ownerWorkspaceID.uuidString.lowercased()
        }
    }

    /// Envelope origin kind: local or SSH relay.
    var kind: String {
        switch self {
        case .local: return "local"
        case .sshRelay: return "ssh-relay"
        }
    }

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// Parses the current local or workspace-scoped SSH wire format.
    init?(wireValue: String) {
        if wireValue == Self.localWireValue {
            self = .local
        } else if wireValue.hasPrefix(Self.sshRelayWirePrefix),
                  let id = UUID(uuidString: String(wireValue.dropFirst(Self.sshRelayWirePrefix.count))) {
            self = .sshRelay(ownerWorkspaceID: id)
        } else {
            return nil
        }
    }
}

extension TerminalNotificationOrigin: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let origin = Self(wireValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported notification origin")
        }
        self = origin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Informational origin of a local or user-controlled SSH notification; never hook-patchable.
struct TerminalNotificationPolicyOriginContext: Codable, Sendable, Equatable {
    var kind: String
    var value: String

    init(_ origin: TerminalNotificationOrigin) {
        kind = origin.kind
        value = origin.wireValue
    }
}
