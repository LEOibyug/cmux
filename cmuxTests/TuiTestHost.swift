import CmuxCore
import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import CmuxTui
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A user-controlled SSH configuration for provider tests that install their own daemon graph.
struct TuiTestHost {
    let connection: SSHTuiConnection

    init(destination: String) {
        connection = SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            destination: destination, port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil
        ))
    }

    init(connection: SSHTuiConnection) {
        self.connection = connection
    }

    var summary: RemoteTuiMachine { .ssh(connection) }
    var machine: SurfaceMachineID { summary.machine }

    /// No network connection is made while constructing this real SSH carrier.
    func links() -> SSHTuiLinkManager {
        SSHTuiLinkManager(connection: connection, clientURL: URL(fileURLWithPath: "/usr/bin/false"),
            paths: TuiClientPaths(), isEnabled: { true })
    }
}
