import Foundation

/// Resolves the managed policy for user-created SSH, Mosh and remote tmux connections.
public struct ManagedRemoteConnectionsPolicy: Sendable {
    private let policy: ManagedDevicePolicy

    /// Creates a remote-connection policy resolver.
    /// - Parameter policy: The managed-device preference source.
    public init(policy: ManagedDevicePolicy = ManagedDevicePolicy()) {
        self.policy = policy
    }

    /// Whether an administrator disables user-created remote connections.
    public var isDisabled: Bool { policy.isEnforced(.disableRemoteConnections) }

    /// Whether user-created remote connections may proceed.
    public var isEnabled: Bool { !isDisabled }

    /// The explanation shown when a connection is refused.
    public var disabledMessage: String {
        String(localized: "managedPolicy.remoteConnections.disabled", defaultValue: "Remote connections are disabled by your organization.")
    }
}
