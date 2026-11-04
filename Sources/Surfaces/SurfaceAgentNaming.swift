import CmuxRemoteSession
import Foundation

/// A provider that persists automatic names with a daemon-side user/epoch check.
@MainActor
protocol SurfaceAgentNaming: SurfaceProvider {
    func renameAgentTab(context: TuiAgentNameContext, name: String) async throws
}
