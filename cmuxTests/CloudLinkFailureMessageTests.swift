import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SSH link failure messages")
struct TuiLinkFailureMessageTests {
    @Test("states and diagnostics produce user-facing link failure copy")
    func linkFailureMessageUsesStateAndProse() {
        let unavailable = machineInfo(linkState: .unavailable)
        #expect(unavailable.linkFailureMessage == "cmux cannot reach this SSH host. Check the host and reconnect.")
        let unavailableError = RemoteMachineLink.LinkError.failureMessage(unavailable.linkFailureMessage)
        #expect(RemoteMachineLink.errorText(unavailableError) == unavailable.linkFailureMessage)
        let reasonCode = machineInfo(linkState: .error, linkError: "daemon_not_ready")
        #expect(reasonCode.linkFailureMessage == TuiTransportError.connectionClosed.localizedDescription)

        let prose = machineInfo(linkState: .error, linkError: "The remote daemon did not respond before the timeout.")
        #expect(prose.linkFailureMessage == "The remote daemon did not respond before the timeout.")

        let empty = machineInfo(linkState: .error, linkError: "")
        #expect(empty.linkFailureMessage == TuiTransportError.connectionClosed.localizedDescription)
        #expect(machineInfo(linkState: .error).linkFailureMessage == TuiTransportError.connectionClosed.localizedDescription)
    }

    private func machineInfo(linkState: SurfaceLinkState, linkError: String? = nil) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .ssh("1aff7397771028e602bc6c858b709ac4a595822ad6d0607c3402ba9e47c35cd0"),
            name: "Link copy test",
            status: "running",
            linkState: linkState,
            linkError: linkError
        )
    }
}
