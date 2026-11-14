import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceDragBlockResolverTests {
    private let resolver = SidebarWorkspaceDragBlockResolver()

    @Test(arguments: [0, 2, 3])
    func selectedWorkspaceExpandsToEntireSelectionInSidebarOrder(draggedIndex: Int) {
        let ids = (0..<4).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[3], ids[0], ids[2]],
            draggedId: ids[draggedIndex]
        )

        #expect(movingIds == [ids[0], ids[2], ids[3]])
    }

    @Test func nonMemberMovesOnlyTheDraggedWorkspace() {
        let ids = (0..<3).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[0], ids[1]],
            draggedId: ids[2]
        )

        #expect(movingIds == [ids[2]])
    }

    @Test func contiguousBlockIsNotNoncontiguous() {
        let ids = (0..<5).map { _ in UUID() }

        #expect(!resolver.blockOccupiesNoncontiguousRows(
            blockIds: [ids[1], ids[2]],
            rowSpaceIds: ids
        ))
    }

    @Test func gappedBlockIsNoncontiguous() {
        let ids = (0..<5).map { _ in UUID() }

        #expect(resolver.blockOccupiesNoncontiguousRows(
            blockIds: [ids[1], ids[3]],
            rowSpaceIds: ids
        ))
    }

    @Test func singleRowBlockIsNotNoncontiguous() {
        let ids = (0..<3).map { _ in UUID() }

        #expect(!resolver.blockOccupiesNoncontiguousRows(
            blockIds: [ids[1]],
            rowSpaceIds: ids
        ))
    }

    @Test func blockMembersAbsentFromRowSpaceAreIgnored() {
        let ids = (0..<4).map { _ in UUID() }
        let foreign = UUID()

        // Only ids[1] is present in the row space; a lone present member
        // cannot span a gap.
        #expect(!resolver.blockOccupiesNoncontiguousRows(
            blockIds: [ids[1], foreign],
            rowSpaceIds: ids
        ))
    }
}
