import CmuxCore
public import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceResource {
    public var tuiProcessDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title).processTitle
        return value.isEmpty ? String(localized: "tuiTree.terminal.untitled", defaultValue: "terminal") : value
    }

    public var tuiPoolDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title, viewNames: remoteViews?.map(\.name) ?? []).poolTitle
        return value.isEmpty ? tuiProcessDisplayTitle : value
    }
}
