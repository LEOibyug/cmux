import AppKit
import CmuxRemoteSession
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TuiWorkspaceCreationSidebarFixture {
    private let previousApp = AppDelegate.shared
    private let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
    let app = AppDelegate()
    let manager: TabManager
    let catalog: SurfaceCatalog
    let provider: TuiWorkspaceCreationSidebarProvider
    let window: NSWindow
    let windowID = UUID()
    let originalWorkspaceID: UUID
    private let defaults: UserDefaults
    private let defaultsName = "cloud-workspace-creation-\(UUID().uuidString)"
    private let previousSharedRenameService: TuiWorkspaceRenameService?
    init(useSharedCatalog: Bool = false, machine: SurfaceMachineID? = nil) throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = TabManager(settings: UserDefaultsSettingsClient(defaults: defaults))
        originalWorkspaceID = try #require(manager.selectedTabId)
        let owner = manager
        let ownerEnvironment = TuiWorkspaceRenameEnvironment(
            workspace: { owner.workspacesById[$0] }, tabManager: { _ in owner }, workspaces: { owner.tabs }
        )
        if useSharedCatalog {
            // The shared catalog's rename service was installed by the host
            // app delegate and resolves workspaces through that delegate's
            // windows, which never contain this fixture's manager. Without
            // this, bindRemoteWorkspace is a no-op and reservations never get
            // their remoteWorkspaceBinding.
            let shared = SurfaceCatalog.shared
            previousSharedRenameService = shared.tuiWorkspaceRenameService
            shared.installTuiWorkspaceRenameService(TuiWorkspaceRenameService(environment: ownerEnvironment))
            catalog = shared
        } else {
            previousSharedRenameService = nil
            catalog = SurfaceCatalog(tuiWorkspaceRenameService: TuiWorkspaceRenameService(environment: ownerEnvironment))
        }
        if let machine {
            provider = TuiWorkspaceCreationSidebarProvider(catalog: catalog, machine: machine)
        } else {
            provider = TuiWorkspaceCreationSidebarProvider(catalog: catalog)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        AppDelegate.shared = app
        // This fixture owns a short-lived app delegate and exercises Cloud
        // projections only. Keep session autosave disabled so an async
        // persistence block cannot become the last owner of `app` and run its
        // main-actor service deinitializers on the persistence worker queue.
        app.isTerminatingApp = true
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(window, windowId: windowID, tabManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(),
                               fileExplorerState: FileExplorerState())
        catalog.register(provider)
    }

    var workspaces: [SurfaceRemoteWorkspace] {
        catalog.snapshot.machines.first { $0.id == provider.machine }?.remoteWorkspaces ?? []
    }

    func create(name: String? = nil, focus: Bool, reuseFailedCreation: Bool = false) async throws
        -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        try await catalog.tuiWorkspaceCreationCoordinator.create(
            provider: provider, name: name, focus: focus,
            host: TuiWorkspaceCreationHost(manager: manager), reuseFailedCreation: reuseFailedCreation,
            existingWorkspace: nil, existingTerminal: nil
        )
    }

    func close() {
        app.isTerminatingApp = true
        provider.beforeRefresh = nil
        provider.beforeMaterialize = nil
        provider.beforeCreate = nil
        provider.afterCreateWorkspace = nil
        catalog.unregister(machine: provider.machine)
        manager.tabs.forEach { $0.teardownAllPanels() }
        app.unregisterMainWindowContextForTesting(windowId: windowID)
        window.close()
        if let previousSharedRenameService {
            catalog.installTuiWorkspaceRenameService(previousSharedRenameService)
        }
        AppDelegate.shared = previousApp
        TerminalController.shared.setActiveTabManager(previousManager)
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
