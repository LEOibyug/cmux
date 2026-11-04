import CmuxRemoteSession
import Foundation
import Observation

/// Shares user-controlled SSH port routes until the owning provider retires them.
@MainActor
@Observable
final class RemotePortAccessStore {
    struct Key: Hashable {
        let machineID: String
        let port: Int
        let scheme: String
        let targetHost: String
        let route: RemotePortAccessRoute
    }

    private(set) var models: [Key: RemotePortAccessModel] = [:]

    func model(
        machineID: String,
        target: RemotePortForwardTarget,
        scheme: String = "http",
        route: RemotePortAccessRoute = .loopback,
        make: () -> RemotePortAccessModel
    ) -> RemotePortAccessModel {
        let key = Key(
            machineID: machineID,
            port: target.port,
            scheme: scheme.lowercased(),
            targetHost: target.host.lowercased(),
            route: route
        )
        if let existing = models[key], existing.phase != .closed {
            existing.updateTarget(target)
            return existing
        }
        let model = make()
        models[key] = model
        return model
    }

    func remove(machineID: String) async {
        let keys = models.keys.filter { $0.machineID == machineID }
        for key in keys {
            if let model = models.removeValue(forKey: key) {
                await model.retire()
            }
        }
    }
}
