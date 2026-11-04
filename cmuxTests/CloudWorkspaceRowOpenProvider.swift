import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Native panes with a controllable attachment boundary and no guest mutations.
@MainActor
final class CloudWorkspaceRowOpenProvider: SurfaceProvider {
    let machine: SurfaceMachineID
    let info: SurfaceMachineInfo
    var gate: RemoteLinkFirstValue<Bool>?
    let started = RemoteLinkFirstValue<Bool>()
    var materializations = 0
    var failAt: Int?
    var remoteCloses = 0

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func refresh() async {}
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw TuiTransportError.placementMismatch
    }
    func closeRemoteWorkspace(id: String) async throws { remoteCloses += 1 }
    func closeTerminal(_ id: SurfaceResourceID) async throws { remoteCloses += 1 }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: nil, at: destination, focus: focus, adopting: nil)
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool, adopting reservation: TuiTerminalPaneReservation?) async throws -> SurfaceProjection {
        materializations += 1
        started.resolve(true)
        if let gate { _ = await gate.result }
        if materializations == failAt { throw TuiTransportError.placementMismatch }
        let pane: (workspaceID: UUID, panelID: UUID)
        if let reservation {
            pane = (reservation.workspaceID, reservation.panelID)
        } else if resource.kind == .terminal {
            let created = try SurfacePaneFactory.makeTuiManualMirrorPane(at: destination, focus: focus, onInput: { _ in },
                keyNameResolver: nil, onResize: { _ in }, onRuntimeReady: {}, onFocus: {})
            pane = (created.workspaceID, created.panelID)
        } else {
            pane = try SurfacePaneFactory.makeBrowserPane(url: nil, at: destination, focus: focus)
        }
        let view = remoteView ?? resource.remoteViews?.first
        return SurfaceProjection(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID,
            remoteWorkspaceID: view?.workspace.id, remoteTabID: view?.tabID)
    }
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}
