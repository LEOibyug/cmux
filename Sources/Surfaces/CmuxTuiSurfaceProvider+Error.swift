import CmuxRemoteSession
import Foundation

/// Failures of an SSH host's terminal and browser provider.
extension CmuxTuiSurfaceProvider {
    enum ProviderError: Error, LocalizedError {
        case connectionUnavailable(String)
        case noWorkspaceOnMachine(String)
        case remoteWorkspaceNotFound(String)
        case remotePlacementUnavailable(String)
        case remoteTabNotFound(String)
        case terminalNotCreated(String)
        case browserNotCreated
        /// The terminal's process already ended on the machine.
        case terminalExited(String)
        /// The daemon did not answer the resolver within the bounded retries.
        /// The terminal may still be running; this is never "not created".
        case terminalAttachTimedOut(terminalID: String, failure: TuiSurfaceIDResolution.Failure)
        case invalidSnapshot(String)
        case snapshotOnly(String)
        case stateUnavailable(String)
        case tabStateUnavailable(String)
        case invalidPreviewURL
        /// The private URL could not be rewritten onto the loopback forward.
        case localForwardURLUnavailable

        var errorDescription: String? {
            switch self {
            case .connectionUnavailable(let id):
                return String(format: String(localized: "ssh.tui.hostDisconnected", defaultValue: "The SSH connection to %@ is unavailable. Reconnect the host, then retry."), id)
            case .noWorkspaceOnMachine(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.noWorkspaceOnMachine",
                        defaultValue: "%@ has no remote workspace yet."
                    ),
                    id
                )
            case .remoteWorkspaceNotFound(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.remoteWorkspaceNotFound",
                        defaultValue: "Remote workspace %@ is no longer available. Refresh and retry."
                    ),
                    id
                )
            case .remotePlacementUnavailable(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.remotePlacementUnavailable",
                        defaultValue: "Remote workspace %@ has no available terminal placement. Refresh and retry."
                    ),
                    id
                )
            case .remoteTabNotFound(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.remoteTabNotFound",
                        defaultValue: "Remote tab %@ is no longer available. Refresh and retry."
                    ),
                    id
                )
            case .terminalNotCreated(let detail):
                return String(
                    format: String(
                        localized: "tuiTree.error.terminalNotCreated",
                        defaultValue: "The SSH host did not report the new terminal: %@"
                    ),
                    detail
                )
            case .browserNotCreated:
                return String(localized: "ssh.tui.browserUnavailable", defaultValue: "The SSH host could not create a browser tab. Refresh the host and retry.")
            case .terminalExited(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.terminalExited",
                        defaultValue: "%@ already exited on the machine."
                    ),
                    id
                )
            case let .terminalAttachTimedOut(terminalID, failure):
                return String(
                    format: String(
                        localized: "tuiTree.error.terminalAttachTimedOut",
                        defaultValue: "Could not attach %@ in time (%@). The terminal may still be running on the machine; try opening it again."
                    ),
                    terminalID,
                    failure.localizedDescription
                )
            case .invalidSnapshot(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.invalidSnapshot",
                        defaultValue: "The SSH host returned an unversioned or malformed session snapshot for %@."
                    ),
                    id
                )
            case .snapshotOnly(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.snapshotOnly",
                        defaultValue: "%@ uses an older cmux-tui protocol. Install a compatible cmux-tui on the SSH host to enable live sync and rename operations."
                    ),
                    id
                )
            case .stateUnavailable(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.renameTerminalUnavailable",
                        defaultValue: "The current state for %@ is unavailable. Refresh and retry before renaming."
                    ),
                    id
                )
            case .tabStateUnavailable(let id):
                return String(
                    format: String(
                        localized: "tuiTree.error.renameTabUnavailable",
                        defaultValue: "The current state for tab %@ is unavailable. Refresh and retry before renaming."
                    ),
                    id
                )
            case .invalidPreviewURL:
                return String(
                    localized: "tuiTree.error.invalidPreviewURL",
                    defaultValue: "The SSH host returned an unusable preview address. Refresh and retry."
                )
            case .localForwardURLUnavailable:
                return String(
                    localized: "tuiTree.error.localForwardURLUnavailable",
                    defaultValue: "cmux could not build a local address for this port forward."
                )
            }
        }

    }

}
