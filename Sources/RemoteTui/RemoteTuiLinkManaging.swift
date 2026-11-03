import CmuxRemoteSession
import Foundation

/// Supplies a machine's shared cmux-tui carrier independently of its hosting provider.
protocol RemoteTuiLinkManaging: Sendable {
    func connected(machineID: String) async throws -> RemoteMachineLink.Connected
    func link(machineID: String) async -> RemoteMachineLink?
    func status(machineID: String) async -> RemoteMachineLink.Status?
    func privateAddresses(for machineID: String) async -> [String]
    func loopbackForward(machineID: String, port: Int, onExit: @escaping @Sendable () -> Void) async throws -> UInt16
    func closeLoopbackForward(machineID: String, port: Int) async
    func browserProxy(machineID: String, remoteNetwork: Bool) async throws -> RemoteBrowserProxyEndpoint
}

extension RemoteTuiLinkManaging {
    func browserProxy(machineID: String) async throws -> RemoteBrowserProxyEndpoint {
        try await browserProxy(machineID: machineID, remoteNetwork: false)
    }
}

