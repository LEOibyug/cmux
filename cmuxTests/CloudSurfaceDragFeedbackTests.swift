import CmuxRemoteSession
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
private final class CountingCloudDragDestination: NSView {
    var enteredCount = 0
    var updatedCount = 0
    var exitedCount = 0

    /// Records the first native callback and accepts the drag.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        enteredCount += 1
        return .move
    }

    /// Records updates forwarded to the same destination.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updatedCount += 1
        return .move
    }

    /// Records an unexpected destination transition.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        exitedCount += 1
    }
}

@MainActor
private final class ChurningCloudDragRootView: NSView {
    var nextHitTestResult: NSView?

    /// Returns one injected portal hit before restoring normal hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let nextHitTestResult {
            self.nextHitTestResult = nil
            return nextHitTestResult
        }
        return super.hitTest(point)
    }
}

@MainActor
@Suite("Cloud drag validation and feedback", .serialized)
struct CloudSurfaceDragFeedbackTests {
    @Test("Cloud pane forwarding stays stable while the pointer remains in one pane")
    /// Keeps the original pane destination through a transient portal hit-test result.
    func destinationStaysValidDuringPortalHitTestChurn() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb").rawValue)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let root = ChurningCloudDragRootView(frame: window.contentLayoutRect)
        let destination = CountingCloudDragDestination(frame: NSRect(x: 20, y: 20, width: 120, height: 120))
        destination.registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
        root.addSubview(destination)
        let portalHost = NSView(frame: root.bounds)
        root.addSubview(portalHost, positioned: .below, relativeTo: destination)
        let gate = TuiSurfaceDropGateView(frame: root.bounds, sourceResolver: fixture.resolver)
        gate.workspace = fixture.workspace
        gate.isActive = true
        root.addSubview(gate)
        window.contentView = root
        window.orderFront(nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-drag-stability-\(UUID())"))
        #expect(fixture.registration.write(to: pasteboard))
        let sender = SurfaceDraggingInfo(source: NSOutlineView(), pasteboard: pasteboard, location: NSPoint(x: 80, y: 80))

        #expect(gate.draggingEntered(sender) == .move)
        root.nextHitTestResult = portalHost
        #expect(gate.draggingUpdated(sender) == .move)
        #expect(destination.enteredCount == 1)
        #expect(destination.updatedCount == 1)
        #expect(destination.exitedCount == 0)
    }

    @Test("The pure rule rejects unknown/local/foreign owners and preserves local destinations")
    func policy() {
        let policy = SurfaceOwnershipPolicy(remoteMachine: .ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d"))
        for owner in [nil, SurfaceMachineID.local, .ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")] {
            #expect(policy.rejection(for: owner) == .remoteMachineMismatch)
            #expect(SurfaceOwnershipPolicy(remoteMachine: nil).rejection(for: owner) == nil)
        }
        #expect(policy.rejection(for: .ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d")) == nil)
        #expect(policy.rejection(for: [SurfaceResourceID]()) == .remoteMachineMismatch)
    }

    @Test("A surface already in the Cloud workspace can be reordered or split within it")
    func ownSurfaceMovesWithinWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d").rawValue)
        let panelID = try #require(workspace.focusedPanelId)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        // The workspace's own terminal is local here, the case a Cloud workspace
        // holding a pre-existing local split hits; its own Cloud terminals follow
        // the same path.
        #expect(workspace.machineOwningSurface(panelID) == .local)
        let own = PaneDragTransfer(tabId: tabID.uuid, sourcePaneId: paneID.id, sourceProcessId: processID)
        #expect(workspace.surfaceDropRejection(own, source: .surface) == nil)
        #expect(workspace.canPerformPortalSurfaceDrop(own))

        let foreign = PaneDragTransfer(tabId: UUID(), sourcePaneId: paneID.id, sourceProcessId: processID)
        #expect(workspace.surfaceDropRejection(foreign, source: .surface) == .remoteMachineMismatch)
        let otherProcess = PaneDragTransfer(tabId: tabID.uuid, sourcePaneId: paneID.id, sourceProcessId: processID &+ 1)
        #expect(workspace.surfaceDropRejection(otherProcess, source: .surface) == .remoteMachineMismatch)
    }

    @Test("SwiftUI gate and AppKit pane router agree for every resource kind", arguments: SurfaceResourceKind.allCases)
    func destinationParity(kind: SurfaceResourceKind) throws {
        let fixture = try CloudSurfaceDragFixture(kind: kind)
        defer { fixture.finish() }
        let gate = TuiSurfaceDropGateView(frame: NSRect(x: 0, y: 0, width: 240, height: 240), sourceResolver: fixture.resolver)
        gate.workspace = fixture.workspace
        gate.isActive = true
        for destination in ["b", "a"] {
            let owner = destination == "a"
                ? SurfaceMachineID.ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
                : SurfaceMachineID.ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d")
            fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: owner.rawValue)
            let router = fixture.router()
            let result = router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right)
            if kind == .browser || destination == "a" {
                // Browser surfaces can be moved between Cloud and local
                // workspaces. Terminal and display ownership stays strict.
                guard case .accepted = result else { Issue.record("Same-machine drop was rejected"); return }
                #expect(gate.rejection(for: fixture.pasteboard) == nil)
            } else {
                #expect(result == .rejected)
                #expect(router.rejection == .remoteMachineMismatch)
                #expect(gate.rejection(for: fixture.pasteboard) == router.rejection)
            }
            router.clear()
            #expect(router.rejection == nil)
        }
    }

    @Test("Browser surface transfers are allowed into and out of Cloud workspaces")
    func browserTransfersRemainPortable() throws {
        let tuiWorkspace = Workspace()
        let localWorkspace = Workspace()
        defer {
            tuiWorkspace.teardownAllPanels()
            localWorkspace.teardownAllPanels()
        }
        tuiWorkspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("56681010b753e1abe52c449d0aab291b28f1808a3a91b6baeaa726883baad4b0").rawValue)
        let transfer = PaneDragTransfer(tabId: UUID(), sourcePaneId: UUID(), sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier))
        let browserGroup = SurfaceResourceGroup(title: "Browser", resources: [SurfaceResourceID(machine: .local, kind: .browser, key: "browser")])
        #expect(tuiWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(browserGroup)) == nil)
        let cloudBrowserGroup = SurfaceResourceGroup(title: "Browser", resources: [SurfaceResourceID(machine: .ssh("56681010b753e1abe52c449d0aab291b28f1808a3a91b6baeaa726883baad4b0"), kind: .browser, key: "browser")])
        #expect(localWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(cloudBrowserGroup)) == nil)
        let mixedTerminalGroup = SurfaceResourceGroup(title: "mixed", resources: [
            SurfaceResourceID(machine: .local, kind: .browser, key: "browser"),
            SurfaceResourceID(machine: .local, kind: .terminal, key: "terminal")
        ])
        #expect(tuiWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(mixedTerminalGroup)) == .remoteMachineMismatch)
    }

    @Test("Rebinding after hover is rejected before mutation", arguments: [SurfaceResourceKind.terminal])
    func destinationChangesBeforeDrop(kind: SurfaceResourceKind) throws {
        let fixture = try CloudSurfaceDragFixture(kind: kind)
        defer { fixture.finish() }
        fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb").rawValue)
        let router = fixture.router()
        guard case .accepted(let plan) = router.resolve(
            pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right
        ) else { Issue.record("Same-machine hover should be accepted"); return }
        let panels = Set(fixture.workspace.panels.keys)
        let panes = fixture.workspace.bonsplitController.allPaneIds
        fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d").rawValue)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
        #expect(Set(fixture.workspace.panels.keys) == panels)
        #expect(fixture.workspace.bonsplitController.allPaneIds == panes)
        #expect(router.rejection == nil)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
    }

    @Test("A revoked capability cannot execute a previously accepted plan")
    func staleDragCannotPerform() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .browser)
        defer { fixture.finish() }
        fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb").rawValue)
        let router = fixture.router()
        guard case .accepted(let plan) = router.resolve(
            pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .center
        ) else { Issue.record("Same-machine hover should be accepted"); return }
        fixture.registry.end(fixture.registration)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
        #expect(router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right) == .rejected)
        router.clear()
    }

    @Test("Warning is red, wrapped, accessible, and cleared on cancel or completion")
    func warningLifecycle() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        let view = TuiSurfaceDropGateView(frame: NSRect(x: 0, y: 0, width: 240, height: 240), sourceResolver: fixture.resolver)
        view.workspace = fixture.workspace
        view.isActive = true
        let sender = SurfaceDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        let expected = "SSH workspaces can only hold terminals from their own SSH host. Browser tabs can move freely. Open a local workspace to move other splits there."
        #expect(SurfaceTransferRejection.remoteMachineMismatch.message == expected)
        #expect(view.draggingEntered(sender).isEmpty)
        #expect(view.feedback.rejection == .remoteMachineMismatch)
        #expect(!view.feedback.badge.isHidden)
        #expect(view.feedback.badge.accessibilityLabel() == expected)
        #expect(view.feedback.badge.frame.width <= view.bounds.width)
        #expect(view.feedback.badge.frame.height > 26)
        let label = try #require(view.feedback.badge.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(label.textColor == .systemRed)
        #expect(label.maximumNumberOfLines == 0)
        #expect(!view.acceptsFirstResponder)
        #expect(!view.prepareForDragOperation(sender))
        view.draggingExited(sender)
        #expect(view.feedback.rejection == nil)
        #expect(view.feedback.badge.isHidden)
        #expect(view.feedback.badge.superview == nil)
        #expect(view.draggingEntered(sender).isEmpty)
        #expect(!view.performDragOperation(sender))
        #expect(view.feedback.rejection == nil)
        #expect(view.feedback.badge.isHidden)
        // Rejection leaves the native source in charge of completing its lease.
        #expect(fixture.registry.resolve(from: fixture.pasteboard) != nil)
        view.draggingEnded(sender)
        view.isActive = false
        #expect(view.rejection(for: fixture.pasteboard) == nil)
    }

    @Test("Legacy JSON cannot bypass the live capability registry")
    func legacyPayloadIsRejected() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("{\"tab\":{\"id\":\"\(UUID())\"},\"sourcePaneId\":\"\(UUID())\",\"sourceProcessId\":1}", forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        let router = fixture.router()
        #expect(router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .center) == .rejected)
        #expect(router.rejection == .remoteMachineMismatch)
        router.clear()
    }


    @Test("Pane warnings stay outside the sidebar and onscreen beside short splits", arguments: [false, true])
    func paneWarningPlacement(short: Bool) throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil }
        let frame = NSRect(x: 0, y: short ? 420 : 0, width: 240, height: short ? 80 : 500)
        let gate = TuiSurfaceDropGateView(frame: frame, sourceResolver: fixture.resolver)
        root.addSubview(gate)
        gate.workspace = fixture.workspace
        gate.isActive = true
        let sender = SurfaceDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        #expect(gate.draggingEntered(sender).isEmpty)
        let host = try #require(gate.feedback.badge.superview)
        #expect(host === window.contentView?.superview)
        let paneBounds = host.convert(gate.bounds, from: gate)
        #expect(gate.feedback.badge.frame.minX >= paneBounds.minX)
        #expect(gate.feedback.badge.frame.maxX <= paneBounds.maxX)
        #expect(host.bounds.contains(gate.feedback.badge.frame))
        if !short { #expect(paneBounds.contains(gate.feedback.badge.frame)) }
        gate.draggingExited(sender)
        #expect(gate.feedback.badge.superview == nil)
        #expect(gate.draggingEntered(sender).isEmpty)
        window.contentView = nil
        #expect(gate.feedback.badge.superview == nil)
        #expect(gate.feedback.rejection == nil)
    }

    @Test("Every pane destination boundary clears its warning", arguments: [
        "exit", "end", "conclude", "prepare", "drop", "inactive", "workspace", "hide", "detach", "empty", "sameVM", "nonTransfer"
    ])
    func paneWarningCleanup(boundary: String) throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        let gate = TuiSurfaceDropGateView(frame: root.bounds, sourceResolver: fixture.resolver)
        root.addSubview(gate)
        gate.workspace = fixture.workspace
        gate.isActive = true
        let sender = SurfaceDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        #expect(gate.draggingEntered(sender).isEmpty)
        #expect(gate.feedback.rejection == .remoteMachineMismatch)
        switch boundary {
        case "exit": gate.draggingExited(sender)
        case "end": gate.draggingEnded(sender)
        case "conclude": gate.concludeDragOperation(sender)
        case "prepare": #expect(!gate.prepareForDragOperation(sender))
        case "drop": #expect(!gate.performDragOperation(sender))
        case "inactive": gate.isActive = false
        case "workspace": gate.workspace = nil
        case "hide": gate.isHidden = true
        case "detach": gate.removeFromSuperview()
        case "empty":
            gate.setFrameSize(.zero)
            #expect(gate.draggingUpdated(sender).isEmpty)
        case "sameVM":
            fixture.workspace.remoteWorkspaceBinding = RemoteWorkspaceBinding(machineID: SurfaceMachineID.ssh("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb").rawValue)
            #expect(gate.draggingUpdated(sender).isEmpty)
            #expect(gate.rejection(for: fixture.pasteboard) == nil)
            guard case .accepted = fixture.router().resolve(
                pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right
            ) else { Issue.record("Same-VM drops must still reach the pane destination"); return }
        case "nonTransfer":
            fixture.pasteboard.clearContents()
            #expect(gate.draggingUpdated(sender).isEmpty)
        default: Issue.record("Unknown lifecycle boundary")
        }
        #expect(gate.feedback.rejection == nil)
        #expect(gate.feedback.badge.isHidden)
        #expect(gate.feedback.badge.superview == nil)
    }
}
