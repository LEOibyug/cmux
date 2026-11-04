/// Request categories tracked while an SSH manual-mirror handshake is in flight.
///
/// Resize requests retain the exact grid they carried. A response can arrive
/// after a visibility transition has reset the scheduler, so acknowledging by
/// request kind alone could accidentally retire a newer grid.
public enum TuiManualMirrorRequestKind: Equatable, Sendable {
    case identify
    case clientInfo
    case attach
    case resize(TuiManualIOGrid)
    case claim
    /// The watchdog's liveness probe; any answer proves the stream is alive.
    case ping
    /// A shared-sizing mutation or `get-size-state`; the answer may carry state.
    case sizing
}
