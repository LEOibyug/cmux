import CmuxRemoteSession
import CmuxTui
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Delivers `entries` to the machine's `~/.config/cmux/env` over the link — see
    /// `TuiEnvDelivery` for the protocol and why no other channel is acceptable.
    /// Returns what the receiver reported; throws with the receiver's own reason when
    /// it refused, and with an "outdated shim" explanation when the machine does not
    /// know the verb yet.
    func deliverEnvironment(_ entries: [TuiEnvDelivery.Entry]) async throws -> TuiEnvDelivery.Outcome {
        let payload = try TuiEnvDelivery.payload(entries)
        let wire = TuiEnvDelivery.wire(payload)
        var receiver: SurfaceResource?
        return try await TuiEnvDelivery.withReceiverWorkspace(
            createWorkspace: { try await self.createEnvironmentReceiverWorkspace() },
            closeWorkspace: { try await self.removeEnvironmentReceiverWorkspace($0, receiver: receiver) },
            operation: { workspaceID in
                let created = try await self.createTerminal(
                    command: TuiEnvDelivery.receiverCommand,
                    cwd: nil,
                    name: TuiEnvDelivery.receiverTitle,
                    remoteWorkspaceID: workspaceID,
                    onExit: "keep"
                )
                receiver = created
                return try await self.deliverEnvironmentWire(wire, terminalID: created.id.key)
            }
        )
    }

    private func removeEnvironmentReceiverWorkspace(_ workspaceID: String, receiver: SurfaceResource?) async throws {
        try await TuiEnvDelivery.removeReceiverResources(
            terminalIDs: receiver.map { [$0.id.key] } ?? [],
            discoverTerminalIDs: {
                guard await self.refreshCurrentGraph(force: true) else {
                    throw TuiEnvDelivery.DeliveryError.workspaceCleanupFailed(workspaceID)
                }
                return self.catalog.snapshot.resources(on: self.machine).filter {
                    $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
                }.map { $0.id.key }
            },
            closeTerminal: { terminalID in
                do {
                    try await self.closeTerminal(
                        SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID)
                    )
                } catch {
                    guard Self.isSelectorNotFound(error) else { throw error }
                }
            },
            closeWorkspace: {
                do {
                    try await self.closeRemoteWorkspace(id: workspaceID)
                } catch {
                    guard Self.isSelectorNotFound(error) else { throw error }
                }
            }
        )
    }

    private func createEnvironmentReceiverWorkspace() async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        let result = try await link.run(arguments: TuiRequests.createWorkspaceArguments(
            socketPath: connected.socketPath,
            name: "\(TuiEnvDelivery.receiverTitle) \(UUID().uuidString)",
            empty: true
        ))
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let workspaceID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        return workspaceID
    }

    private func deliverEnvironmentWire(_ wire: Data, terminalID: String) async throws -> TuiEnvDelivery.Outcome {
        let ready = try await waitForScreen(
            terminalID: terminalID,
            pattern: TuiEnvDelivery.readyMarker,
            timeoutMs: TuiEnvDelivery.readyTimeoutMs
        )
        try TuiEnvDelivery.requireReady(ready, machineID: machineID)
        // Echo is off on the receiver's PTY from here on; the daemon never journals
        // input, so the payload exists on the machine only inside the receiver.
        for chunk in TuiEnvDelivery.chunks(wire) {
            try await writeBytes(terminalID: terminalID, data: chunk)
        }
        let result = try await waitForScreen(
            terminalID: terminalID,
            pattern: TuiEnvDelivery.resultPattern,
            timeoutMs: TuiEnvDelivery.resultTimeoutMs
        )
        return try TuiEnvDelivery.requireOutcome(result)
    }

    /// ASCII receiver-wire bytes reach the terminal through stdin, never process argv.
    func writeBytes(terminalID: String, data: Data) async throws {
        _ = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.connectionUnavailable(machineID) }
        _ = try await link.run(
            arguments: TuiRequests.writeBytes(terminalID: terminalID, data: data)
        )
    }
}
