import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudSurfaceDragFixture {
    let workspace = Workspace()
    let registry = TabDragTransferRegistry()
    let registration: TabDragTransferRegistration
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-ownership-\(UUID())"))
    let context: PaneDropContext
    let resolver: PaneTransferSourceResolver

    init(kind: SurfaceResourceKind) throws {
        workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d").rawValue)
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        context = PaneDropContext(workspaceId: workspace.id, panelId: panelID, paneId: paneID)
        let transfer = TabDragTransfer(tab: Tab(title: "same name", kind: kind.rawValue), sourcePaneId: PaneID(id: UUID()))
        registration = try #require(registry.register(transfer))
        let registry = registry
        let group = SurfaceResourceGroup(title: "same name", resources: [
            SurfaceResourceID(machine: .ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"), kind: kind, key: "resource")
        ])
        resolver = PaneTransferSourceResolver(
            vaultSessionRegistry: { nil }, tabTransferRegistry: { registry },
            filePreview: { _ in nil },
            surfaceResource: { $0 == transfer.tab.id.uuid ? group : nil },
            surfaceIsLive: { _ in false }
        )
        #expect(registration.write(to: pasteboard))
    }

    func router() -> PaneTransferDropRouter {
        PaneTransferDropRouter(containerResolver: { [workspace] _ in workspace }, sourceResolver: resolver)
    }

    func finish() {
        registry.end(registration)
        pasteboard.clearContents()
        workspace.teardownAllPanels()
    }
}
