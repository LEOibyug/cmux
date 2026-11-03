/// Lifecycle of one SSH terminal's byte attachment.
public enum TuiManualMirrorPhase: Equatable, Sendable {
    case idle
    case connecting
    case attached
    case disconnected
    case stopped
}
