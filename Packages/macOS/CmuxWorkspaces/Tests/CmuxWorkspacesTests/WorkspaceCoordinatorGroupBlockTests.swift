import Foundation
import Testing

@testable import CmuxWorkspaces

/// Block (multi-selection) drops scoped inside a workspace group section,
/// mirroring `SidebarWorkspaceReorderDropResolver.groupScopedPlan`: full row
/// space, removal-adjusted target index, and an explicit group id.
@MainActor
struct WorkspaceCoordinatorGroupBlockTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        return (model, host, groups, reorder)
    }

    /// Group of four members plus two loose rows below the section:
    /// `[anchor, m1, m2, m3, m4, l1, l2]`.
    private func makeGroupWorld() throws -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>,
        groupId: UUID,
        anchorId: UUID,
        m1: CoordinatorStubTab,
        m2: CoordinatorStubTab,
        m3: CoordinatorStubTab,
        m4: CoordinatorStubTab,
        l1: CoordinatorStubTab,
        l2: CoordinatorStubTab
    ) {
        let (model, host, groups, reorder) = makeWorld()
        let m1 = CoordinatorStubTab()
        let m2 = CoordinatorStubTab()
        let m3 = CoordinatorStubTab()
        let m4 = CoordinatorStubTab()
        let l1 = CoordinatorStubTab()
        let l2 = CoordinatorStubTab()
        model.tabs = [m1, m2, m3, m4, l1, l2]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G"))
        groups.addWorkspaceToGroup(workspaceId: m1.id, groupId: groupId)
        groups.addWorkspaceToGroup(workspaceId: m2.id, groupId: groupId)
        groups.addWorkspaceToGroup(workspaceId: m3.id, groupId: groupId)
        groups.addWorkspaceToGroup(workspaceId: m4.id, groupId: groupId)
        let anchorId = try #require(model.workspaceGroups.first?.anchorWorkspaceId)
        try #require(model.tabs.map(\.id) == [anchorId, m1.id, m2.id, m3.id, m4.id, l1.id, l2.id])
        return (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2)
    }

    @Test
    func inGroupBlockDropLandsAtMemberGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m3} selected; drop at the gap above m4
        // (index 3 in the order without m1, clamped inside the section).
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m3.id],
            draggedTabId: m1.id,
            toIndex: 3,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m2.id, m1.id, m3.id, m4.id, l1.id, l2.id])
        #expect(m1.groupId == groupId)
        #expect(m3.groupId == groupId)
    }

    @Test
    func inGroupBlockHopsOverNextMember() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m2} selected; drop at the gap above m4: the
        // block hops over m3 together.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m2.id],
            draggedTabId: m1.id,
            toIndex: 3,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m3.id, m1.id, m2.id, m4.id, l1.id, l2.id])
    }

    @Test
    func inGroupBlockDropAtSectionBottomGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m3} selected; drop at the section's bottom gap
        // (below m4, group lane): index 4 in the order without m1.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m3.id],
            draggedTabId: m1.id,
            toIndex: 4,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m2.id, m4.id, m1.id, m3.id, l1.id, l2.id])
        #expect(m1.groupId == groupId)
        #expect(m3.groupId == groupId)
    }

    @Test
    func inGroupBlockDropAtSectionTopGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m3 with {m3, m4} selected; drop just below the anchor
        // (index 1 in the order without m3).
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m3.id, m4.id],
            draggedTabId: m3.id,
            toIndex: 1,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m3.id, m4.id, m1.id, m2.id, l1.id, l2.id])
    }

    @Test
    func inGroupAdjacentBlockDropAtOwnBoundaryIsAcceptedNoOp() throws {
        let (model, host, reorder, groupId, _, m1, m2, m3, _, _, _) = try makeGroupWorld()
        _ = m3

        // Grabbed m1 with {m1, m2} selected; drop at the gap directly below
        // the block (between m2 and m3). With the block removed that gap is
        // where the block already sits, so the order is unchanged — but the
        // drop was still accepted at a painted gap and must report success,
        // not a refusal (a false here makes AppKit animate a snap-back).
        let before = model.tabs.map(\.id)
        let orderChangesBefore = host.orderChanges.count
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m2.id],
            draggedTabId: m1.id,
            toIndex: 2,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == before)
        #expect(host.orderChanges.count == orderChangesBefore)
    }

    @Test
    func blockSpanningGroupBoundaryJoinsGroupOnExplicitDrop() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed l1 with {l1, m2} selected; drop at the gap above m4 inside
        // the section (index 4 in the order without l1): the block lands
        // there in sidebar order (m2 before l1) and l1 joins the group.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [l1.id, m2.id],
            draggedTabId: l1.id,
            toIndex: 4,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m1.id, m3.id, m2.id, l1.id, m4.id, l2.id])
        #expect(l1.groupId == groupId)
        #expect(m2.groupId == groupId)
    }

    @Test(arguments: ["anchorDrag", "memberDrag", "anchorKeyboard"])
    func ordinaryMemberReorderPromotesTheFirstRow(interaction: String) throws {
        let (model, host, groups, reorder) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [a, b, c, outside]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "Source",
            childWorkspaceIds: [a.id, b.id, c.id]
        ))
        let moveAnchor = interaction != "memberDrag"
        let draggedId = moveAnchor ? a.id : c.id
        #expect(!reorder.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: b.id
        ))
        #expect(reorder.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedId,
            targetWorkspaceId: b.id
        ) == 0...3)
        var expectedGroup = try #require(model.workspaceGroups.first)
        expectedGroup.anchorWorkspaceId = moveAnchor ? b.id : c.id
        expectedGroup.anchorWorkspaceProvenance = .user

        if interaction == "anchorKeyboard" {
            #expect(reorder.reorderWorkspace(tabId: draggedId, toIndex: 1))
        } else {
            #expect(reorder.reorderSidebarWorkspace(
                tabId: draggedId,
                toIndex: moveAnchor ? 1 : 0,
                isDragOperation: true,
                explicitGroupId: groupId
            ))
        }

        let expectedWorkspaceIds: [UUID] = moveAnchor
            ? [b.id, a.id, c.id, outside.id]
            : [c.id, a.id, b.id, outside.id]
        #expect(model.tabs.map(\.id) == expectedWorkspaceIds)
        #expect(model.workspaceGroups == [expectedGroup])
        #expect(host.closedWorkspaceIds.isEmpty)
    }

    @Test(arguments: [false, true])
    func mixedAnchorMemberBlockTransfersEveryRequestedWorkspace(isPinned: Bool) throws {
        let (model, host, groups, reorder) = makeWorld()
        let firstMember = CoordinatorStubTab()
        let secondAnchor = CoordinatorStubTab()
        let remainingMember = CoordinatorStubTab()
        let targetAnchor = CoordinatorStubTab()
        let targetMember = CoordinatorStubTab()
        model.tabs = [firstMember, secondAnchor, remainingMember, targetAnchor, targetMember]
        let firstGroupId = try #require(groups.createWorkspaceGroup(name: "Generated source", selectAnchor: false))
        groups.addWorkspaceToGroup(workspaceId: firstMember.id, groupId: firstGroupId)
        groups.setWorkspaceGroupPinned(groupId: firstGroupId, isPinned: isPinned)
        let firstAnchorId = try #require(model.workspaceGroups.first { $0.id == firstGroupId }?.liveAnchorWorkspaceId)
        let secondGroupId = try #require(groups.createWorkspaceGroup(
            name: "Surviving source",
            childWorkspaceIds: [secondAnchor.id, remainingMember.id],
            selectAnchor: false
        ))
        groups.setWorkspaceGroupCollapsed(groupId: secondGroupId, isCollapsed: true)
        var expectedSource = try #require(model.workspaceGroups.first { $0.id == secondGroupId })
        expectedSource.anchorWorkspaceId = remainingMember.id
        expectedSource.anchorWorkspaceProvenance = .user
        let targetGroupId = try #require(groups.createWorkspaceGroup(
            name: "Target",
            childWorkspaceIds: [targetAnchor.id, targetMember.id],
            selectAnchor: false
        ))
        let targetIndex = try #require(model.tabs.filter { $0.id != firstAnchorId }
            .firstIndex { $0.id == targetMember.id })

        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [secondAnchor.id, firstMember.id, firstAnchorId],
            draggedTabId: firstAnchorId,
            toIndex: targetIndex,
            isDragOperation: true,
            explicitGroupId: targetGroupId
        ))

        #expect(model.tabs.map(\.id) == [remainingMember.id, targetAnchor.id, firstAnchorId,
            firstMember.id, secondAnchor.id, targetMember.id])
        #expect(model.tabs.filter { $0.groupId == targetGroupId }.map(\.id) == [targetAnchor.id,
            firstAnchorId, firstMember.id, secondAnchor.id, targetMember.id])
        #expect(model.workspaceGroups.first { $0.id == secondGroupId } == expectedSource)
        let firstSource = model.workspaceGroups.first { $0.id == firstGroupId }
        #expect(firstSource?.isEmpty == (isPinned ? true : nil))
        #expect(firstSource?.isPinned == (isPinned ? true : nil))
        #expect(host.closedWorkspaceIds.isEmpty)
    }

    @Test(arguments: [false, true])
    func ordinaryAnchorCanLeaveItsGroupWithoutMovingItsPeers(isPinned: Bool) throws {
        let (model, host, groups, reorder) = makeWorld()
        let anchor = CoordinatorStubTab()
        let peer = CoordinatorStubTab()
        let outside1 = CoordinatorStubTab()
        let outside2 = CoordinatorStubTab()
        model.tabs = [anchor, peer, outside1, outside2]
        let sourceId = try #require(groups.createWorkspaceGroup(
            name: "Source",
            childWorkspaceIds: [anchor.id, peer.id]
        ))
        groups.setWorkspaceGroupPinned(groupId: sourceId, isPinned: isPinned)
        groups.setWorkspaceGroupCollapsed(groupId: sourceId, isCollapsed: true)
        var expectedSource = try #require(model.workspaceGroups.first)
        expectedSource.anchorWorkspaceId = peer.id
        expectedSource.anchorWorkspaceProvenance = .user
        #expect(reorder.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: anchor.id,
            usesTopLevelRows: true
        ) == [sourceId, anchor.id, outside1.id, outside2.id])
        #expect(reorder.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: anchor.id,
            usesTopLevelRows: true
        ) == (isPinned ? [sourceId] : []))

        #expect(reorder.reorderSidebarWorkspace(
            tabId: anchor.id,
            toIndex: 3,
            isDragOperation: true,
            usesTopLevelRows: true
        ))

        #expect(model.tabs.map(\.id) == [peer.id, outside1.id, outside2.id, anchor.id])
        #expect(model.workspaceGroups == [expectedSource])
        #expect(anchor.groupId == nil)
        #expect(peer.groupId == sourceId)
        #expect(model.selectedTabId == anchor.id)
        #expect(host.closedWorkspaceIds.isEmpty)
    }

    @Test(arguments: [false, true])
    func soleAnchorPromotionUsesTheSourceHeaderAndRootRowSpace(isPinned: Bool) throws {
        let (model, host, groups, reorder) = makeWorld()
        let anchor = CoordinatorStubTab()
        let root1 = CoordinatorStubTab()
        let root2 = CoordinatorStubTab()
        model.tabs = [anchor, root1, root2]
        let sourceId = try #require(groups.createWorkspaceGroup(name: "Source", childWorkspaceIds: [anchor.id]))
        groups.setWorkspaceGroupPinned(groupId: sourceId, isPinned: isPinned)
        #expect(reorder.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: anchor.id,
            usesTopLevelRows: true
        ) == [sourceId, anchor.id, root1.id, root2.id])

        #expect(reorder.reorderSidebarWorkspace(
            tabId: anchor.id,
            toIndex: 2,
            isDragOperation: true,
            usesTopLevelRows: true
        ))

        #expect(model.tabs.map(\.id) == [root1.id, anchor.id, root2.id])
        #expect(model.tabs.allSatisfy { $0.groupId == nil })
        #expect(model.workspaceGroups.first?.isEmpty == (isPinned ? true : nil))
        #expect(model.workspaceGroups.first?.id == (isPinned ? sourceId : nil))
        #expect(host.closedWorkspaceIds.isEmpty)
    }

    @Test
    func memberPinPrefixIncludesTheStoredAnchor() throws {
        let (model, host, groups, reorder) = makeWorld()
        let anchor = CoordinatorStubTab(isPinned: true)
        let pinnedMember = CoordinatorStubTab(isPinned: true)
        let unpinnedMember = CoordinatorStubTab()
        model.tabs = [anchor, pinnedMember, unpinnedMember]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "Source",
            childWorkspaceIds: [anchor.id, pinnedMember.id, unpinnedMember.id]
        ))
        #expect(reorder.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: anchor.id,
            explicitGroupId: groupId
        ) == 0...2)
        #expect(reorder.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: unpinnedMember.id,
            explicitGroupId: groupId
        ) == 2...3)

        #expect(reorder.reorderSidebarWorkspace(
            tabId: anchor.id,
            toIndex: 2,
            isDragOperation: true,
            explicitGroupId: groupId
        ))

        #expect(model.tabs.map(\.id) == [pinnedMember.id, anchor.id, unpinnedMember.id])
        #expect(model.workspaceGroups.first?.anchorWorkspaceId == pinnedMember.id)
        #expect(host.closedWorkspaceIds.isEmpty)
    }
}
