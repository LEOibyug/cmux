import CmuxFoundation
import Foundation

/// Maps the live reorder indicator onto per-row drop-line flags for the
/// AppKit sidebar table. Wraps the shared `SidebarTabDropIndicatorPredicate`
/// (identical gap semantics to the SwiftUI sidebar) and additionally
/// suppresses lines on the row being dragged: AppKit snapshots that row as
/// the drag image lazily, so any line painted there gets baked into the
/// ghost and travels with the pointer for the rest of the drag.
struct SidebarWorkspaceTableReorderIndicatorPainter {
    let indicator: SidebarDropIndicator?
    let scope: SidebarWorkspaceReorderDropIndicatorScope
    let draggedWorkspaceId: UUID
    /// Scope-filtered row ids in display order, from the same
    /// `sidebarDropIndicatorRowIds` computation the SwiftUI sidebar feeds the
    /// predicate, so adjacency and end-of-scope answers cannot diverge.
    let indicatorRowIds: [UUID]

    func paint(
        forRowWorkspaceId rowWorkspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool
    ) -> (top: Bool, bottom: Bool) {
        let rowId: UUID
        switch scope {
        case .raw:
            guard !isGroupHeader else { return (false, false) }
            rowId = rowWorkspaceId
        case .topLevel:
            guard isGroupHeader || groupId == nil else { return (false, false) }
            guard let identity = isGroupHeader ? groupId : rowWorkspaceId else { return (false, false) }
            rowId = identity
        case .group(let targetGroupId):
            guard groupId == targetGroupId else { return (false, false) }
            if isGroupHeader {
                guard indicatorRowIds.allSatisfy({ $0 == targetGroupId }),
                      let indicator,
                      indicator.tabId == targetGroupId || indicator.tabId == rowWorkspaceId,
                      draggedWorkspaceId != targetGroupId,
                      draggedWorkspaceId != rowWorkspaceId else { return (false, false) }
                // With no rendered members, adoption is represented by the
                // container's lower edge even when the hidden anchor is the
                // resolver's top-edge target.
                return (false, true)
            }
            rowId = rowWorkspaceId
        }
        guard indicator != nil else { return (false, false) }
        guard rowId != draggedWorkspaceId else { return (false, false) }
        let predicate = SidebarTabDropIndicatorPredicate()
        return (
            top: predicate.topVisible(
                forTabId: rowId,
                draggedTabId: draggedWorkspaceId,
                dropIndicator: indicator,
                tabIds: indicatorRowIds
            ),
            bottom: predicate.bottomVisible(
                forTabId: rowId,
                draggedTabId: draggedWorkspaceId,
                dropIndicator: indicator,
                tabIds: indicatorRowIds,
                indicatorScope: scope
            )
        )
    }
}
