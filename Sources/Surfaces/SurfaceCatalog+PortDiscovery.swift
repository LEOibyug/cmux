import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Explicit catalog refreshes are user inventory requests, so they opt a
    /// machine into demand-driven port discovery without enabling background polls.
    func requestPortDiscovery(for machine: SurfaceMachineID) {
        (provider(for: machine) as? CmuxTuiSurfaceProvider)?.requestPortDiscovery()
    }

    /// User refresh scans the connected SSH host without a control-plane lookup.
    func refreshPortDiscovery(machine: SurfaceMachineID) async {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else { return }
        let request = provider.requestPortDiscovery()
        guard provider.isRegisteredInCatalog(), !Task.isCancelled else {
            provider.abandonPortDiscoveryRequest(request)
            return
        }
        await provider.refresh(force: true)
        // A cancelled SSH refresh must not strand its request in the loading state.
        if Task.isCancelled { provider.abandonPortDiscoveryRequest(request) }
    }
}
