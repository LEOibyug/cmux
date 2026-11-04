public import CmuxTui
public import CmuxCore

/// Transport state consumed by the pane's presentation owner.
public struct RemoteManualMirrorPresentation: Sendable {
    public init(
        phase: TuiManualMirrorPhase,
        replayReceived: Bool
    ) {
        self.phase = phase
        self.replayReceived = replayReceived
    }

    public let phase: TuiManualMirrorPhase
    public let replayReceived: Bool

    public var connectionState: WorkspaceRemoteConnectionState? {
        switch phase {
        case .idle: return nil
        case .connecting: return .connecting
        case .attached: return replayReceived ? .connected : .connecting
        case .disconnected: return .error
        case .stopped: return nil
        }
    }
}
