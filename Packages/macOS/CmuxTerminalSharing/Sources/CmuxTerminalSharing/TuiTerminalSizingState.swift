import CmuxTerminalSizing

/// Connection-scoped sizing state for this Mac's user-controlled SSH terminal view.
public struct TuiTerminalSizingState: Sendable {
    /// The shared-sizing capability negotiated with the remote daemon.
    public static let capability = "shared-sizing-v1"
    /// The capability for detaching only this Mac's view.
    public static let viewDetachCapability = "sizing-view-detach-v1"
    /// Whether the current connection negotiated shared sizing.
    public private(set) var isSupported = false
    /// Whether the current daemon can detach only this view.
    public private(set) var supportsViewDetach = false
    /// The participant identity established by this connection's attachment.
    public private(set) var selfParticipantID: String?
    /// The most recent generation accepted on this connection.
    public private(set) var state: TerminalSizingState?
    /// Creates a disconnected sizing view.
    public init() {}
    /// Starts a connection, discarding identities and generations from the previous connection.
    /// - Parameter capabilities: Capabilities returned by the daemon identify handshake.
    public mutating func connectionStarted(capabilities: Set<String>) {
        isSupported = capabilities.contains(Self.capability)
        supportsViewDetach = isSupported && capabilities.contains(Self.viewDetachCapability)
        selfParticipantID = nil
        state = nil
    }
    /// Records the participant owned by the acknowledged attachment.
    /// - Parameter selfParticipantID: The participant from the attach receipt.
    public mutating func attached(selfParticipantID: String?) { self.selfParticipantID = selfParticipantID }
    /// Accepts a new sizing generation without allowing stale replies to rewind it.
    /// - Parameter next: The state received from the current connection.
    /// - Returns: Whether a different, non-stale state was accepted.
    @discardableResult
    public mutating func receive(_ next: TerminalSizingState) -> Bool {
        if let state, state == next || next.generation < state.generation { return false }
        state = next
        return true
    }
}
