/// User-facing connection-state strings the coordinator publishes, resolved
/// app-side so `String(localized:)` binds to the app bundle's localization
/// tables (the package never localizes). Keys and default values are
/// identical to the legacy controller's inline `String(localized:)` calls.
public struct RemoteSessionStrings: Sendable, Equatable {
    /// Format for an attach-only SSH/mosh connection with the remote helper
    /// deliberately disabled (`remote.state.connected.withoutDaemon`).
    /// `%@` is the display target.
    public let connectedWithoutDaemonFormat: String
    /// Format for the suspended-auto-reconnect state detail
    /// (`remote.state.suspended.detail`); `%@` is the display target.
    public let suspendedDetailFormat: String
    /// Retry detail when the reverse SSH relay is unavailable.
    public let reverseRelayUnavailableRetrying: String
    /// Retry detail when a live owner prevents relay-port recovery.
    public let reverseRelayPortUnavailableRetrying: String
    /// Detail when another cmux process temporarily owns the SSH master.
    public let controlMasterOwnershipUnavailable: String
    /// Safe product-facing detail for a non-retryable proxy failure.
    public let remoteProxyUnavailable: String

    /// Creates the app-resolved strings bundle.
    ///
    /// - Parameters:
    ///   - connectedWithoutDaemonFormat: Attach-only connection detail format.
    ///   - suspendedDetailFormat: Suspended reconnect detail format.
    ///   - reverseRelayUnavailableRetrying: Generic relay retry detail.
    ///   - reverseRelayPortUnavailableRetrying: Port-conflict retry detail.
    ///   - controlMasterOwnershipUnavailable: Cross-process ownership detail.
    public init(
        connectedWithoutDaemonFormat: String,
        suspendedDetailFormat: String,
        reverseRelayUnavailableRetrying: String,
        reverseRelayPortUnavailableRetrying: String,
        controlMasterOwnershipUnavailable: String,
        remoteProxyUnavailable: String = "Remote proxy unavailable"
    ) {
        self.connectedWithoutDaemonFormat = connectedWithoutDaemonFormat
        self.suspendedDetailFormat = suspendedDetailFormat
        self.reverseRelayUnavailableRetrying =
            reverseRelayUnavailableRetrying
        self.reverseRelayPortUnavailableRetrying =
            reverseRelayPortUnavailableRetrying
        self.controlMasterOwnershipUnavailable =
            controlMasterOwnershipUnavailable
        self.remoteProxyUnavailable = remoteProxyUnavailable
    }
}
