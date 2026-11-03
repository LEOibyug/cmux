import CmuxRemoteSession
import CmuxTerminal
import Foundation

/// The native pane and transport owner returned by cloud materialization.
struct TuiManualMirrorMaterialization {
    let workspaceID: UUID
    let panelID: UUID
    let surface: TerminalSurface
    let session: TuiManualMirrorSession
    var remotePlacement: SurfaceRemotePlacement? = nil
}
