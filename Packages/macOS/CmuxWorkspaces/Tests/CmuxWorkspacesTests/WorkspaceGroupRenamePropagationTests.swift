import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace group rename propagation")
struct WorkspaceGroupRenamePropagationTests {
    @Test(arguments: [false, true])
    func renameChangesOnlyGroupMetadata(generatedAnchor: Bool) throws {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let coordinator = WorkspaceGroupCoordinator(model: model)
        coordinator.attach(host: host)
        let member = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [member, outside]
        let groupId = try #require(coordinator.createWorkspaceGroup(
            name: "Before",
            childWorkspaceIds: generatedAnchor ? [] : [member.id],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        var expectedGroup = try #require(model.workspaceGroups.first)
        expectedGroup.name = "After"
        let originalOrder = model.tabs.map(\.id)
        let originalMembership = model.tabs.map(\.groupId)
        let originalSelection = model.selectedTabId
        let orderChangeCount = host.orderChanges.count

        coordinator.renameWorkspaceGroup(groupId: groupId, name: " After ")
        coordinator.renameWorkspaceGroup(groupId: groupId, name: "After")
        coordinator.renameWorkspaceGroup(groupId: groupId, name: "  ")

        #expect(model.workspaceGroups == [expectedGroup])
        #expect(model.tabs.map(\.id) == originalOrder)
        #expect(model.tabs.map(\.groupId) == originalMembership)
        #expect(model.selectedTabId == originalSelection)
        #expect(host.groupNameChangeCount == 1)
        #expect(host.orderChanges.count == orderChangeCount)
        #expect(host.closedWorkspaceIds.isEmpty)
    }
}
