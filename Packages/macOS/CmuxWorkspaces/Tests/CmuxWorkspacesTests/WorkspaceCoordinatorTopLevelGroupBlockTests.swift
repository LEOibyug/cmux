import Foundation
import Testing

@testable import CmuxWorkspaces

/// Group UUIDs move whole sections; workspace UUIDs never stand in for headers.
@MainActor
struct WorkspaceCoordinatorTopLevelGroupBlockTests {
    @Test(arguments: [2, 99])
    func groupHeaderMovesItsWholeSection(targetIndex: Int) throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        let originalGroups = fixture.model.workspaceGroups
        let publicationCount = fixture.host.orderChanges.count

        #expect(fixture.reorder.reorderSidebarGroup(groupId: fixture.group1Id, toIndex: targetIndex))
        let movedSection = [fixture.anchor1Id, fixture.group1Child1.id, fixture.group1Child2.id]
        let otherSection = [fixture.anchor2Id, fixture.group2Child.id]
        let expected = otherSection + movedSection + [fixture.loose1.id, fixture.loose2.id, fixture.loose3.id]
        #expect(fixture.model.tabs.map(\.id) == expected)
        #expect(fixture.model.workspaceGroups == [originalGroups[1], originalGroups[0]])
        #expect(fixture.host.orderChanges.count == publicationCount + 1)
        #expect(fixture.host.orderChanges.last == movedSection)
        #expect(fixture.host.closedWorkspaceIds.isEmpty)
    }

    @Test
    func groupHeaderClampsToItsPinTierWithoutChangingMembership() throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group1Id, isPinned: true)
        let originalOrder = fixture.model.tabs.map(\.id)
        let originalGroups = fixture.model.workspaceGroups
        let publicationCount = fixture.host.orderChanges.count

        #expect(fixture.reorder.reorderSidebarGroup(groupId: fixture.group1Id, toIndex: 99))
        #expect(fixture.model.tabs.map(\.id) == originalOrder)
        #expect(fixture.model.workspaceGroups == originalGroups)
        #expect(fixture.host.orderChanges.count == publicationCount)
        #expect(fixture.host.closedWorkspaceIds.isEmpty)
    }

    @Test
    func emptyPinnedGroupHeaderMovesWithoutAnyLiveWorkspace() throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group1Id, isPinned: true)
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: true)
        let emptyId = UUID()
        fixture.model.workspaceGroups.insert(WorkspaceGroup(
            id: emptyId,
            name: "Empty",
            isCollapsed: true,
            isPinned: true,
            anchor: .empty(emptyId),
            customColor: nil,
            iconSymbol: nil
        ), at: 0)
        let originalOrder = fixture.model.tabs.map(\.id)

        #expect(fixture.reorder.reorderSidebarGroup(groupId: emptyId, toIndex: 99))
        #expect(fixture.model.workspaceGroups.map(\.id) == [fixture.group1Id, fixture.group2Id, emptyId])
        #expect(fixture.model.tabs.map(\.id) == originalOrder)
        #expect(fixture.model.workspaceGroups.last?.isEmpty == true)
        #expect(fixture.host.closedWorkspaceIds.isEmpty)
        #expect(!fixture.reorder.reorderSidebarGroup(groupId: UUID(), toIndex: 0))
    }

    @Test(arguments: ["workspace", "drag", "notification", "moveToTop", "batch"])
    func independentWorkspacesCannotCrossGroupTiers(operation: String) throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.reorder.setPinned(fixture.loose1, pinned: true)
        fixture.reorder.setPinned(fixture.loose2, pinned: true)
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: true)
        let pinnedSection = [fixture.anchor2Id, fixture.group2Child.id]
        let regularSection = [fixture.anchor1Id, fixture.group1Child1.id, fixture.group1Child2.id]
        let expected = pinnedSection + [fixture.loose1.id, fixture.loose2.id]
            + regularSection + [fixture.loose3.id]

        switch operation {
        case "workspace":
            #expect(fixture.reorder.workspaceReorderPlan(tabId: fixture.loose1.id, toIndex: 0)?.toIndex == 2)
            #expect(fixture.reorder.workspaceReorderPlan(tabId: fixture.loose3.id, toIndex: 0)?.toIndex == 7)
            #expect(fixture.reorder.reorderWorkspace(tabId: fixture.loose1.id, toIndex: 0))
            #expect(fixture.reorder.reorderWorkspace(tabId: fixture.loose3.id, toIndex: 0))
        case "drag":
            #expect(fixture.reorder.reorderSidebarWorkspace(
                tabId: fixture.loose3.id, toIndex: 0,
                isDragOperation: true, usesTopLevelRows: true
            ))
        case "notification":
            #expect(fixture.reorder.isAtTopOfUnpinnedTier(fixture.loose3.id))
            fixture.reorder.moveTabToTopForNotification(fixture.loose3.id)
        case "moveToTop":
            fixture.reorder.moveTabsToTop([fixture.loose1.id, fixture.loose3.id])
        default:
            let result = fixture.reorder.reorderWorkspaces(
                orderedWorkspaceIds: [fixture.loose3.id, fixture.loose1.id], dryRun: true
            )
            guard case .success(let plan) = result else {
                Issue.record("Expected a tier-clamped batch plan")
                return
            }
            #expect(plan.map(\.toIndex) == [7, 2])
            _ = fixture.reorder.reorderWorkspaces(orderedWorkspaceIds: [fixture.loose3.id, fixture.loose1.id])
        }

        #expect(fixture.model.tabs.map(\.id) == expected)
        #expect(fixture.model.workspaceGroups.map(\.id) == [fixture.group2Id, fixture.group1Id])
        #expect(fixture.group1Child1.groupId == fixture.group1Id)
        #expect(fixture.group2Child.groupId == fixture.group2Id)
        #expect(fixture.host.closedWorkspaceIds.isEmpty)
    }

    @Test
    func emptyOnlyGroupsKeepStableTierOrderAcrossPinAndMove() {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let groups = WorkspaceGroupCoordinator(model: model)
        let reorder = WorkspaceReorderCoordinator(model: model)
        let regular1 = UUID()
        let pinned1 = UUID()
        let regular2 = UUID()
        let pinned2 = UUID()
        model.workspaceGroups = [(regular1, false), (pinned1, true), (regular2, false), (pinned2, true)].map {
            WorkspaceGroup(id: $0.0, name: "Empty", isCollapsed: false, isPinned: $0.1,
                anchor: .empty($0.0), customColor: nil, iconSymbol: nil)
        }

        model.normalizeWorkspaceGroupContiguity()
        #expect(model.workspaceGroups.map(\.id) == [pinned1, pinned2, regular1, regular2])
        #expect(reorder.reorderSidebarGroup(groupId: pinned1, toIndex: 99))
        #expect(model.workspaceGroups.map(\.id) == [pinned2, pinned1, regular1, regular2])
        groups.setWorkspaceGroupPinned(groupId: pinned1, isPinned: false)
        #expect(model.workspaceGroups.map(\.id) == [pinned2, pinned1, regular1, regular2])
        groups.moveWorkspaceGroup(groupId: regular2, toIndex: 0)
        #expect(model.workspaceGroups.map(\.id) == [pinned2, regular2, pinned1, regular1])
        #expect(model.tabs.isEmpty)
    }

    @Test(arguments: [false, true])
    func restoringMixedRowsPartitionsWholeGroupsAndKeepsMemberPinsLocal(staleAnchor: Bool) throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: true)
        fixture.reorder.setPinned(fixture.loose1, pinned: true)
        fixture.reorder.setPinned(fixture.loose2, pinned: true)
        fixture.group1Child2.isPinned = true
        let anchor1 = try #require(fixture.model.tabs.first { $0.id == fixture.anchor1Id })
        let anchor2 = try #require(fixture.model.tabs.first { $0.id == fixture.anchor2Id })
        fixture.model.tabs = [fixture.loose3, fixture.group1Child1, fixture.loose2,
            fixture.group2Child, fixture.loose1, anchor1, fixture.group1Child2, anchor2]
        if staleAnchor {
            let groupIndex = try #require(fixture.model.workspaceGroups.firstIndex { $0.id == fixture.group1Id })
            fixture.model.workspaceGroups[groupIndex].anchorWorkspaceId = UUID()
        }

        fixture.model.normalizeWorkspaceGroupContiguity()

        let regularSection = staleAnchor
            ? [fixture.group1Child1.id, fixture.group1Child2.id, fixture.anchor1Id]
            : [fixture.anchor1Id, fixture.group1Child2.id, fixture.group1Child1.id]
        let expected = [fixture.anchor2Id, fixture.group2Child.id, fixture.loose2.id, fixture.loose1.id]
            + regularSection + [fixture.loose3.id]
        #expect(fixture.model.tabs.map(\.id) == expected)
        #expect(fixture.group1Child2.groupId == fixture.group1Id)
        fixture.reorder.moveTabToTop(fixture.group1Child1.id)
        #expect(fixture.model.tabs.map(\.id) == expected)
    }

    @Test
    func pinTransitionsKeepGroupAndMemberTiersIndependent() throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: true)
        fixture.reorder.setPinned(fixture.loose1, pinned: true)
        #expect(fixture.reorder.setPinned(
            workspaceIds: [fixture.loose2.id, fixture.group1Child2.id], pinned: true
        ) == [fixture.loose2.id, fixture.group1Child2.id])
        let group1Section = [fixture.anchor1Id, fixture.group1Child2.id, fixture.group1Child1.id]
        let group2Section = [fixture.anchor2Id, fixture.group2Child.id]
        #expect(fixture.model.tabs.map(\.id) == group2Section
            + [fixture.loose1.id, fixture.loose2.id] + group1Section + [fixture.loose3.id])

        fixture.reorder.setPinned(fixture.loose1, pinned: false)
        #expect(fixture.model.tabs.map(\.id) == group2Section
            + [fixture.loose2.id] + group1Section + [fixture.loose1.id, fixture.loose3.id])
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: false)
        #expect(fixture.model.tabs.map(\.id) == [fixture.loose2.id]
            + group2Section + group1Section + [fixture.loose1.id, fixture.loose3.id])
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group1Id, isPinned: true)
        #expect(fixture.model.tabs.map(\.id) == group1Section
            + [fixture.loose2.id] + group2Section + [fixture.loose1.id, fixture.loose3.id])
        #expect(fixture.group1Child2.groupId == fixture.group1Id)
        #expect(fixture.model.workspaceGroups.first?.anchorWorkspaceId == fixture.anchor1Id)
    }

    @Test
    func batchPlanMatchesWholeGroupOrderWithPinnedMembers() throws {
        let fixture = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        fixture.groups.setWorkspaceGroupPinned(groupId: fixture.group2Id, isPinned: true)
        _ = fixture.reorder.setPinned(workspaceIds: [fixture.loose1.id, fixture.loose2.id,
            fixture.group1Child2.id], pinned: true)
        let requestedIds = [fixture.loose3.id, fixture.group1Child2.id,
            fixture.loose2.id, fixture.group2Child.id]
        let originalIds = fixture.model.tabs.map(\.id)
        guard case .success(let plan) = fixture.reorder.reorderWorkspaces(
            orderedWorkspaceIds: requestedIds, dryRun: true
        ) else {
            Issue.record("Expected a valid full-tab reorder plan")
            return
        }
        #expect(plan.map(\.toIndex) == [7, 5, 2, 1])
        #expect(fixture.model.tabs.map(\.id) == originalIds)

        _ = fixture.reorder.reorderWorkspaces(orderedWorkspaceIds: requestedIds)

        #expect(fixture.model.tabs.map(\.id) == [fixture.anchor2Id, fixture.group2Child.id,
            fixture.loose2.id, fixture.loose1.id, fixture.anchor1Id, fixture.group1Child2.id,
            fixture.group1Child1.id, fixture.loose3.id])
        #expect(fixture.group1Child2.groupId == fixture.group1Id)
    }
}
