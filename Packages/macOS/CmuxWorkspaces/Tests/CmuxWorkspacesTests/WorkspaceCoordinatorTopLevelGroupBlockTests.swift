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
        let expected = targetIndex == 2
            ? otherSection + [fixture.loose1.id] + movedSection + [fixture.loose2.id, fixture.loose3.id]
            : otherSection + [fixture.loose1.id, fixture.loose2.id, fixture.loose3.id] + movedSection
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
}
