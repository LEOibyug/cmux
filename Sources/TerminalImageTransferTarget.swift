import Foundation

enum TerminalImageTransferTarget: Equatable {
    case local
    case remote(TerminalRemoteUploadTarget)
    /// A native remote session never falls back to a local path, including offline mirrors.
    case tui
}
