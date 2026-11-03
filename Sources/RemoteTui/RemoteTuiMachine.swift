import CmuxRemoteSession
import CmuxSurfaceCatalogModel

/// The exact user-selected SSH carrier used by a terminal provider.
enum RemoteTuiMachine: Sendable {
    case ssh(SSHTuiConnection)

    var connection: SSHTuiConnection { switch self { case .ssh(let connection): return connection } }
    var machine: SurfaceMachineID { .ssh(connection.identityDigest) }
    var id: String { machine.rawValue }
    var preferredName: String { connection.configuration.displayTarget }
    var defaultTerminalCommand: [String] { connection.shellCommand }
    var preferredPrivateAddress: String { "127.0.0.1" }
}
