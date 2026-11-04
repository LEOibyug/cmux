import CmuxRemoteSession
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Retires pane-owned transports without ending the remote terminal session.
    func stop(stopReason: TuiManualMirrorStopReason = .tuiUnavailable) async {
        retireTransport(stopReason: stopReason)
        await terminalMutationQueue.waitForIdle()
        await portAccessStore.remove(machineID: machineID)
    }
}
