public import Foundation

/// Sequences every sidebar/socket workspace reorder flow over the window's
/// `WorkspacesModel`: move-to-top, single and batch reorders, drag-driven
/// group-membership inference, top-level (group-row) reorders, and pin-state
/// changes — lifted one-for-one from the legacy TabManager method bodies.
/// Pure plan computation stays in `WorkspaceReorderPlanner`; observable
/// order-change publication inverts through `WorkspaceOrderHosting`.
@MainActor
public final class WorkspaceReorderCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let planner = WorkspaceReorderPlanner()
    private weak var host: (any WorkspaceOrderHosting)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side host for order-change publication.
    public func attach(host: any WorkspaceOrderHosting) {
        self.host = host
    }

    // MARK: - Move to top

    /// Moves one workspace to the top of its sidebar tier.
    public func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    /// Moves workspaces to the top of their sidebar tiers, preserving their
    /// relative order (group members hoist behind their anchors).
    public func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = model.tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: selectedTabs.map(\.id))
            let topLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            let selectedTopLevelIds = model.topLevelWorkspaceIds(for: selectedTabs)
            let selectedTopLevelIdSet = Set(selectedTopLevelIds)
            let desiredTopLevelIds = selectedTopLevelIds
                + topLevelIds.filter { !selectedTopLevelIdSet.contains($0) }
            model.normalizeWorkspaceGroupContiguity(preservingTopLevelIds: desiredTopLevelIds)
        } else {
            let remainingTabs = model.tabs.filter { !tabIds.contains($0.id) }
            let selectedPinned = selectedTabs.filter { $0.isPinned }
            let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
            let remainingPinned = remainingTabs.filter { $0.isPinned }
            let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
            model.tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    /// Whether ``moveTabToTopForNotification(_:)`` would leave the order
    /// unchanged because the workspace (or, when grouped, its top-level row)
    /// already sits first in its regular group or independent-workspace tier.
    /// Pinned and unknown rows return `false`; callers check pinning separately.
    public func isAtTopOfUnpinnedTier(_ tabId: UUID) -> Bool {
        guard let tab = model.tabs.first(where: { $0.id == tabId }), !tab.isPinned else { return false }
        if !model.workspaceGroups.isEmpty {
            guard let topLevelId = model.topLevelWorkspaceIds(for: [tab]).first else { return false }
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return false }
            let topLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            let tiers = model.sidebarOrderTiers()
            guard topLevelIds.first(where: { tiers[$0] == tiers[topLevelId] }) == topLevelId else { return false }
            // A group member is on top only when it also leads its group's
            // unpinned members, the slot moveTabToTopForNotification promotes
            // it to (after the anchor and any pinned members).
            guard let groupId = tab.groupId,
                  let group = model.workspaceGroups.first(where: { $0.id == groupId }),
                  tab.id != group.anchorWorkspaceId else { return true }
            let firstMember = model.tabs.first { $0.groupId == groupId && $0.id != group.anchorWorkspaceId && !$0.isPinned }
            return firstMember?.id == tabId
        }
        return model.tabs.first(where: { !$0.isPinned })?.id == tabId
    }

    /// Moves a workspace to the top of the unpinned tier for a notification
    /// bump; no-ops for pinned rows or rows already at the boundary.
    public func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }), !tab.isPinned else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            guard let topLevelId = model.topLevelWorkspaceIds(for: [tab]).first else { return }
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return }
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [tabId])
            var desiredTopLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            guard let fromIndex = desiredTopLevelIds.firstIndex(of: topLevelId) else { return }
            let targetIndex = model.clampedTopLevelReorderIndex(
                forWorkspaceId: topLevelId,
                targetIndex: 0,
                topLevelIds: desiredTopLevelIds
            )
            if fromIndex != targetIndex {
                let movedId = desiredTopLevelIds.remove(at: fromIndex)
                desiredTopLevelIds.insert(movedId, at: min(targetIndex, desiredTopLevelIds.count))
            }
            model.normalizeWorkspaceGroupContiguity(preservingTopLevelIds: desiredTopLevelIds)
        } else {
            guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            let pinnedCount = model.tabs.filter { $0.isPinned }.count
            guard index != pinnedCount else { return }
            let tab = model.tabs[index]
            guard !tab.isPinned else { return }
            model.replaceTabs { currentTabs in
                var reordered = currentTabs
                let movedTab = reordered.remove(at: index)
                reordered.insert(movedTab, at: pinnedCount)
                return reordered
            }
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    // MARK: - Single reorder

    /// Reorders one workspace to the clamped target index; drag operations
    /// additionally run neighbor-based group-membership inference.
    @discardableResult
    public func reorderWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> Bool {
        if isDragOperation {
            return reorderSidebarWorkspaces(
                tabIds: [tabId],
                draggedTabId: tabId,
                toIndex: targetIndex,
                isDragOperation: true,
                explicitGroupId: explicitGroupId
            )
        }
        if let explicitGroupId,
           !model.workspaceGroups.contains(where: { $0.id == explicitGroupId }) {
            return false
        }
        guard let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex) else { return false }
        guard plan.fromIndex != plan.toIndex else { return true }

        model.replaceTabs { currentTabs in
            var reordered = currentTabs
            let workspace = reordered.remove(at: plan.fromIndex)
            reordered.insert(workspace, at: plan.toIndex)
            return reordered
        }
        if !model.workspaceGroups.isEmpty {
            if let groupId = model.tabs.first(where: { $0.id == tabId })?.groupId {
                model.repairWorkspaceGroupAnchors(groupIds: [groupId], preferringFirstMemberIn: [groupId])
            }
            model.normalizeWorkspaceGroupContiguity()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    /// Reorders relative to a sibling workspace (socket before/after verbs).
    @discardableResult
    public func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil, isDragOperation: Bool = false) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex, isDragOperation: isDragOperation)
    }

    /// The clamped single-workspace reorder plan, or `nil` when unknown.
    public func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if model.tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }
        let workspace = model.tabs[currentIndex]
        let clamped = model.clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    /// The before/after-relative reorder plan, or `nil` when unknown.
    public func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx - 1 : idx
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        if let afterId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx : idx + 1
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        return nil
    }

    // MARK: - Sidebar drag planning

    /// The drag's row-id space: workspace IDs for members, or distinct group
    /// UUIDs and root workspace IDs for top-level rows and promotion.
    public func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return model.tabs.map(\.id)
        }
        return sidebarTopLevelRowIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    /// The pinned subset of the drag's row-id space.
    public func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return Set(model.tabs.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        }
        let rowIds = sidebarTopLevelRowIds(promotingWorkspaceId: draggedWorkspaceId)
        let groupsById = Dictionary(uniqueKeysWithValues: model.workspaceGroups.map { ($0.id, $0) })
        let workspacesById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        return Set(rowIds.filter { groupsById[$0]?.isPinned ?? workspacesById[$0]?.isPinned ?? false })
    }

    /// Header identities remain distinct from member IDs, including while a
    /// sole source member is being planned for promotion out of its group.
    private func sidebarTopLevelRowIds(promotingWorkspaceId: UUID?) -> [UUID] {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: model.workspaceGroups.map {
            ($0.anchorWorkspaceId, $0)
        })
        var rowIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups().map {
            groupsByAnchorId[$0]?.id ?? $0
        }
        guard let promotingWorkspaceId,
              let workspace = model.tabs.first(where: { $0.id == promotingWorkspaceId }),
              let groupId = workspace.groupId,
              let groupIndex = rowIds.firstIndex(of: groupId) else { return rowIds }
        let groupsById = Dictionary(uniqueKeysWithValues: model.workspaceGroups.map { ($0.id, $0) })
        let workspacesById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: workspace.isPinned)
        var lowerBound = 0
        var sameTierCount = 0
        for id in rowIds {
            let group = groupsById[id]
            let rowTier = WorkspaceSidebarOrderTier(
                isGroup: group != nil,
                isPinned: group?.isPinned ?? workspacesById[id]?.isPinned ?? false
            )
            if rowTier.rawValue < tier.rawValue { lowerBound += 1 }
            if rowTier == tier { sameTierCount += 1 }
        }
        let desiredIndex = min(groupIndex + 1, rowIds.count)
        let insertionIndex = min(max(desiredIndex, lowerBound), lowerBound + sameTierCount)
        rowIds.insert(promotingWorkspaceId, at: insertionIndex)
        return rowIds
    }

    /// The legal insertion range for an in-group member drag, or `nil` when
    /// the drag is not constrained to a group section.
    public func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> ClosedRange<Int>? {
        guard !usesTopLevelRows,
              (explicitGroupId != nil || !sidebarReorderUsesTopLevelRows(
                  forDraggedWorkspaceId: draggedWorkspaceId,
                  targetWorkspaceId: targetWorkspaceId
              )),
              let draggedWorkspaceId,
              let draggedWorkspace = model.tabs.first(where: { $0.id == draggedWorkspaceId }),
              let groupId = explicitGroupId ?? draggedWorkspace.groupId,
              model.workspaceGroups.contains(where: { $0.id == groupId }) else {
            return nil
        }
        let memberIndices = model.tabs.indices.filter { model.tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = model.tabs[index]
            if member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex, model.tabs.count)
            let upper = min(firstIndex + pinnedMemberCount, model.tabs.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + pinnedMemberCount, model.tabs.count)
        let upper = min(lastIndex + 1, model.tabs.count)
        return min(lower, upper)...max(lower, upper)
    }

    /// Moves a group header and all its members in top-level row space.
    @discardableResult
    public func reorderSidebarGroup(groupId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else { return false }
        return reorderTopLevelWorkspaceItem(tabId: group.anchorWorkspaceId, toIndex: targetIndex)
    }

    /// Reorders an ordinary workspace row, including an internal group anchor.
    @discardableResult
    public func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> Bool {
        if !isDragOperation, !usesTopLevelRows {
            return reorderWorkspace(tabId: tabId, toIndex: targetIndex, explicitGroupId: explicitGroupId)
        }
        return reorderSidebarWorkspaces(
            tabIds: [tabId],
            draggedTabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
    }

    /// Reorders a sidebar workspace block at one stable drop gap.
    ///
    /// The block preserves live workspace order and splits mixed pin states
    /// into their legal tiers. Every selected workspace, including anchors,
    /// receives the resolved destination membership.
    ///
    /// - Parameters:
    ///   - tabIds: Workspace ids represented by the drag.
    ///   - draggedTabId: The workspace whose row started the drag. The plan's
    ///     `targetIndex` is removal-adjusted for this row alone
    ///     (`SidebarDropPlanner.resolvedTargetIndex`), so the drop gap can
    ///     only be recovered relative to the row space without it.
    ///   - targetIndex: The accepted plan's target index in its row space.
    ///   - isDragOperation: Whether drag-specific group inference applies.
    ///   - usesTopLevelRows: Whether `targetIndex` addresses top-level rows.
    ///   - explicitGroupId: The group explicitly targeted by the drop.
    /// - Returns: Whether the reorder was handled, including an accepted no-op.
    @discardableResult
    public func reorderSidebarWorkspaces(
        tabIds: [UUID],
        draggedTabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> Bool {
        let requestedIds = Set(tabIds)
        let movingTabs = model.tabs.filter { requestedIds.contains($0.id) }
        guard !movingTabs.isEmpty,
              movingTabs.count == requestedIds.count,
              requestedIds.contains(draggedTabId) else { return false }
        let movingIds = movingTabs.map(\.id)
        if let explicitGroupId,
           !model.workspaceGroups.contains(where: { $0.id == explicitGroupId }) {
            return false
        }

        let previousOrder = model.tabs.map(\.id)
        let previousGroupIds = Dictionary(uniqueKeysWithValues: movingTabs.map { ($0.id, $0.groupId) })
        let movingIdSet = Set(movingIds)
        // `targetIndex` is the dragged row's final index in the row space
        // WITHOUT that row. Resolving the reference against the full order
        // instead lands the block one row early whenever the grab row sits
        // above the drop gap, and can never express the bottom gap.
        let referenceRowSpaceIds = (usesTopLevelRows
            ? sidebarTopLevelRowIds(promotingWorkspaceId: draggedTabId)
            : previousOrder
        ).filter { $0 != draggedTabId }
        let referenceWorkspaceId = sidebarBlockReferenceWorkspaceId(
            targetIndex: targetIndex,
            rowSpaceIds: referenceRowSpaceIds,
            movingIds: movingIdSet
        )
        let remainingIds = previousOrder.filter { !movingIdSet.contains($0) }

        let desiredIds = sidebarBlockDesiredWorkspaceIds(
            movingIds: movingIds,
            remainingIds: remainingIds,
            referenceWorkspaceId: referenceWorkspaceId
        )

        if isDragOperation {
            let resolution: SidebarBlockMembershipResolution
            if let explicitGroupId {
                resolution = .assign(explicitGroupId)
            } else if usesTopLevelRows {
                resolution = .assign(nil)
            } else {
                resolution = sidebarBlockMembershipResolution(
                    referenceWorkspaceId: referenceWorkspaceId,
                    remainingIds: remainingIds
                )
            }
            if case .assign(let destinationGroupId) = resolution {
                for workspaceId in movingIds {
                    model.assignGroup(workspaceId: workspaceId, groupId: destinationGroupId)
                }
            }
        }

        let workspacesById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        model.tabs = desiredIds.compactMap { workspacesById[$0] }
        let destinationGroupIds = Set(movingTabs.compactMap(\.groupId))
        let affectedGroupIds = Set(previousGroupIds.values.compactMap { $0 }).union(destinationGroupIds)
        model.repairWorkspaceGroupAnchors(
            groupIds: affectedGroupIds,
            preferringFirstMemberIn: destinationGroupIds
        )
        model.normalizeWorkspaceGroupContiguity()

        let orderChanged = model.tabs.map(\.id) != previousOrder
        let membershipChanged = movingTabs.contains {
            previousGroupIds[$0.id] != $0.groupId
        }
        if orderChanged || membershipChanged {
            host?.workspaceOrderDidChange(movedWorkspaceIds: movingIds)
        }
        // A drop that resolved to the block's own position (common inside a
        // group section, where the painted gap can be the block's boundary)
        // is a handled no-op, not a refusal: reporting false here makes the
        // AppKit table animate a snap-back.
        return true
    }

    private func sidebarBlockReferenceWorkspaceId(
        targetIndex: Int,
        rowSpaceIds: [UUID],
        movingIds: Set<UUID>
    ) -> UUID? {
        // A past-the-end target is the planner's bottom gap ("append"); a nil
        // reference preserves that instead of anchoring to the last row.
        let clampedIndex = max(0, targetIndex)
        guard clampedIndex < rowSpaceIds.count else { return nil }
        var firstRemainingMemberIds: [UUID: UUID] = [:]
        var remainingWorkspaceIds = Set<UUID>()
        for workspace in model.tabs where !movingIds.contains(workspace.id) {
            remainingWorkspaceIds.insert(workspace.id)
            if let groupId = workspace.groupId, firstRemainingMemberIds[groupId] == nil {
                firstRemainingMemberIds[groupId] = workspace.id
            }
        }
        for rowId in rowSpaceIds[clampedIndex...] {
            if remainingWorkspaceIds.contains(rowId) { return rowId }
            if let memberId = firstRemainingMemberIds[rowId] { return memberId }
        }
        return nil
    }

    /// How a block drop resolves group membership for its members.
    private enum SidebarBlockMembershipResolution {
        case assign(UUID?)
        case preserve
    }

    private func sidebarBlockMembershipResolution(
        referenceWorkspaceId: UUID?,
        remainingIds: [UUID]
    ) -> SidebarBlockMembershipResolution {
        let insertionIndex = referenceWorkspaceId
            .flatMap(remainingIds.firstIndex)
            ?? remainingIds.count
        let workspacesById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        let beforeGroupId = insertionIndex > 0
            ? workspacesById[remainingIds[insertionIndex - 1]]?.groupId
            : nil
        let afterGroupId = insertionIndex < remainingIds.count
            ? workspacesById[remainingIds[insertionIndex]]?.groupId
            : nil
        // Matching neighbors decide membership. An ambiguous boundary keeps
        // each member's existing group instead of stripping it to top level.
        guard beforeGroupId == afterGroupId else { return .preserve }
        return .assign(beforeGroupId)
    }

    private func sidebarBlockDesiredWorkspaceIds(
        movingIds: [UUID],
        remainingIds: [UUID],
        referenceWorkspaceId: UUID?
    ) -> [UUID] {
        var desiredIds = remainingIds
        let insertionIndex = referenceWorkspaceId.flatMap(desiredIds.firstIndex) ?? desiredIds.count
        desiredIds.insert(contentsOf: movingIds, at: insertionIndex)
        return desiredIds
    }


    @discardableResult
    private func reorderTopLevelWorkspaceItem(
        tabId: UUID,
        toIndex targetIndex: Int
    ) -> Bool {
        let topLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
        guard !topLevelIds.isEmpty else { return false }
        guard let fromIndex = topLevelIds.firstIndex(of: tabId) else { return false }
        let clampedTarget = model.clampedTopLevelReorderIndex(
            forWorkspaceId: tabId,
            targetIndex: targetIndex,
            topLevelIds: topLevelIds
        )
        guard fromIndex != clampedTarget else { return true }

        var desiredTopLevelIds = topLevelIds
        if fromIndex != clampedTarget {
            let movedId = desiredTopLevelIds.remove(at: fromIndex)
            desiredTopLevelIds.insert(movedId, at: clampedTarget)
        }
        model.normalizeWorkspaceGroupContiguity(preservingTopLevelIds: desiredTopLevelIds)

        let movedWorkspaceIds: [UUID]
        if let group = model.workspaceGroups.first(where: { $0.anchorWorkspaceId == tabId }) {
            movedWorkspaceIds = model.tabs.filter { $0.groupId == group.id }.map(\.id)
        } else {
            movedWorkspaceIds = [tabId]
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return true
    }

    /// Whether a sidebar drag plans in top-level rows (group rows involved
    /// or a grouped child being promoted out of its group).
    public func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.groupId) })
        )
    }

    /// Snapshot variant of `sidebarReorderUsesTopLevelRows` over a caller-
    /// provided membership map.
    public func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        if model.workspaceGroups.contains(where: { $0.id == draggedWorkspaceId || $0.id == targetWorkspaceId }) {
            return true
        }
        guard let draggedWorkspaceGroupId = workspaceGroupIdByWorkspaceId[draggedWorkspaceId],
              draggedWorkspaceGroupId != nil else {
            return false
        }
        // A grouped child dragged over top-level space is leaving the group;
        // plan in top-level rows so the promotion is explicit and ordered.
        guard let targetWorkspaceId else { return true }
        guard let targetWorkspaceGroupId = workspaceGroupIdByWorkspaceId[targetWorkspaceId] else {
            return false
        }
        return targetWorkspaceGroupId == nil
    }

    // MARK: - Batch reorder

    /// Validates a batch reorder request against the live order.
    public func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = planner.batchReorderPlan(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
        guard case .success(let plan) = result else { return result }
        let finalIds = model.sidebarOrderedWorkspaces(preserving: orderedWorkspaceIds).map(\.id)
        let finalIndexes = Dictionary(uniqueKeysWithValues: finalIds.enumerated().map { ($0.element, $0.offset) })
        return .success(plan.map {
            WorkspaceReorderPlanItem(workspaceId: $0.workspaceId, fromIndex: $0.fromIndex, toIndex: finalIndexes[$0.workspaceId]!)
        })
    }

    /// Applies (or dry-runs) a batch reorder, rebuilding `tabs[]` from the
    /// planner's final order and renormalizing group sections.
    @discardableResult
    public func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
        guard case .success(let plan) = result else { return result }
        guard !dryRun else { return result }

        let movedWorkspaceIds = plan
            .filter { $0.fromIndex != $0.toIndex }
            .map(\.workspaceId)
        guard !movedWorkspaceIds.isEmpty else { return result }

        applyWorkspaceBatchReorder(orderedWorkspaceIds: orderedWorkspaceIds)
        host?.workspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func applyWorkspaceBatchReorder(
        orderedWorkspaceIds: [UUID]
    ) {
        model.normalizeWorkspaceGroupRunsPreservingOrder(orderedWorkspaceIds)
        model.syncWorkspaceGroupsOrderToAnchorOrder()
    }


    private func workspaceOrderSnapshots() -> [WorkspaceOrderSnapshot] {
        model.tabs.map { WorkspaceOrderSnapshot(id: $0.id, isPinned: $0.isPinned) }
    }

    // MARK: - Pinning

    /// Toggles the workspace's pin state.
    public func togglePin(tabId: UUID) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = model.tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    /// Sets one workspace's pin state and reorders it into its tier.
    public func setPinned(_ tab: Tab, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    /// Sets pin state for many workspaces at once; returns the ids whose
    /// state actually changed, in request order.
    @discardableResult
    public func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = model.tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Tab] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in model.tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        // Members stay in place and are repartitioned only within their group.
        // Independent rows join the same boundaries as individual pin changes.
        let changedIndependentIds = Set(changedIds.filter { workspacesById[$0]?.groupId == nil })
        let insertionIds = pinned ? changedIds : Array(changedIds.reversed())
        let changedWorkspaces = insertionIds.compactMap { id -> Tab? in
            guard changedIndependentIds.contains(id) else { return nil }
            return workspacesById[id]
        }
        var reordered = model.tabs.filter { !changedIndependentIds.contains($0.id) }
        let tiers = model.sidebarOrderTiers()
        let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: pinned)
        let insertionIndex = reordered.reduce(into: 0) { count, workspace in
            let rowTier = tiers[workspace.id] ?? .workspace
            if rowTier.rawValue < tier.rawValue || (pinned && rowTier == tier) { count += 1 }
        }
        reordered.insert(contentsOf: changedWorkspaces, at: insertionIndex)
        model.tabs = model.sidebarOrderedWorkspaces(preserving: reordered.map(\.id))
        host?.workspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    private func reorderTabForPinnedState(_ tab: Tab) {
        guard model.tabs.contains(where: { $0.id == tab.id }) else { return }
        if tab.groupId != nil {
            model.normalizeWorkspaceGroupContiguity()
            return
        }
        model.replaceTabs { currentTabs in
            var reordered = currentTabs
            guard let currentIndex = reordered.firstIndex(where: { $0.id == tab.id }) else {
                return currentTabs
            }
            let movedTab = reordered.remove(at: currentIndex)
            let tiers = model.sidebarOrderTiers()
            let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: movedTab.isPinned)
            let insertIndex = reordered.reduce(into: 0) { count, workspace in
                let rowTier = tiers[workspace.id] ?? .workspace
                if rowTier.rawValue < tier.rawValue || (movedTab.isPinned && rowTier == tier) {
                    count += 1
                }
            }
            reordered.insert(movedTab, at: insertIndex)
            return reordered
        }
    }
}
