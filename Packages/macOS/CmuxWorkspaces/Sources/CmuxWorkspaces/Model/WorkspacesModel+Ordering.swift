public import Foundation

// Sidebar ordering reads and reorder-index clamps over the model's own
// tabs/groups storage, lifted one-for-one from the legacy private TabManager
// helpers. All are pure reads; mutating flows live on the coordinators.
extension WorkspacesModel {
    /// Group membership, not a member's own pin, determines its outer tier.
    func sidebarOrderTiers() -> [UUID: WorkspaceSidebarOrderTier] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var tiers: [UUID: WorkspaceSidebarOrderTier] = [:]
        tiers.reserveCapacity(tabs.count + workspaceGroups.count)
        for tab in tabs {
            if let groupId = tab.groupId, let group = groupsById[groupId] {
                tiers[tab.id] = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned)
            } else {
                tiers[tab.id] = WorkspaceSidebarOrderTier(isGroup: false, isPinned: tab.isPinned)
            }
        }
        for group in workspaceGroups {
            tiers[group.anchorWorkspaceId] = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned)
        }
        return tiers
    }

    /// Stable, linear partition of top-level rows, including empty headers.
    func sidebarTierOrderedIds(_ ids: [UUID]) -> [UUID] {
        let tiers = sidebarOrderTiers()
        var rowsByTier = Array(repeating: [UUID](), count: WorkspaceSidebarOrderTier.allCases.count)
        for id in ids {
            rowsByTier[(tiers[id] ?? .workspace).rawValue].append(id)
        }
        return rowsByTier.flatMap { $0 }
    }

    /// Resolves a full-tab plan without changing membership or letting a member
    /// move its group into the member's independent-workspace pin tier.
    func sidebarOrderedWorkspaces(preserving desiredIds: [UUID]) -> [Tab] {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var seenIds = Set<UUID>()
        var ordered: [Tab] = []
        ordered.reserveCapacity(tabs.count)
        for id in desiredIds {
            if let tab = tabsById[id], seenIds.insert(id).inserted {
                ordered.append(tab)
            }
        }
        for tab in tabs where seenIds.insert(tab.id).inserted {
            ordered.append(tab)
        }
        var membersByGroupId: [UUID: [Tab]] = [:]
        for tab in ordered {
            if let groupId = tab.groupId, groupsById[groupId] != nil {
                membersByGroupId[groupId, default: []].append(tab)
            }
        }
        var emittedGroupIds = Set<UUID>()
        var rowsByTier = Array(repeating: [Tab](), count: WorkspaceSidebarOrderTier.allCases.count)
        for tab in ordered {
            if let groupId = tab.groupId, let group = groupsById[groupId] {
                guard emittedGroupIds.insert(groupId).inserted else { continue }
                let tier = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned)
                rowsByTier[tier.rawValue].append(contentsOf: anchorFirst(
                    membersByGroupId[groupId] ?? [], anchorId: group.anchorWorkspaceId
                ))
            } else {
                let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: tab.isPinned)
                rowsByTier[tier.rawValue].append(tab)
            }
        }
        return rowsByTier.flatMap { $0 }
    }

    /// Whether the workspace anchors any group.
    public func isWorkspaceGroupAnchor(_ workspaceId: UUID) -> Bool {
        workspaceGroups.contains { $0.liveAnchorWorkspaceId == workspaceId }
    }

    /// The top-level sidebar row id for each given workspace (its group's
    /// anchor when grouped, itself when ungrouped), deduplicated in order.
    func topLevelWorkspaceIds(for workspaces: [Tab]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            let topLevelId: UUID
            if let groupId = workspace.groupId,
               let group = groupsById[groupId] {
                topLevelId = group.anchorWorkspaceId
            } else {
                topLevelId = workspace.id
            }
            if emittedIds.insert(topLevelId).inserted {
                ids.append(topLevelId)
            }
        }
        return ids
    }

    /// The sidebar's top-level row ids in `tabs[]` order (group anchors and
    /// ungrouped workspaces). Optionally inserts a grouped workspace being
    /// promoted to top level as close to its group's row as its pin tier allows.
    func sidebarTopLevelWorkspaceIds(promotingWorkspaceId promotedWorkspaceId: UUID? = nil) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        ids = sidebarTierOrderedIds(ids)
        if let promotedWorkspaceId,
           !ids.contains(promotedWorkspaceId),
           let tab = tabsById[promotedWorkspaceId],
           let groupId = tab.groupId,
           let group = groupsById[groupId],
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceId) {
            ids.insert(
                promotedWorkspaceId,
                at: promotedTopLevelInsertionIndex(
                    ids: ids,
                    groupIndex: groupIndex,
                    promotedIsPinned: tab.isPinned,
                    tabsById: tabsById,
                    groupsByAnchorId: groupsByAnchorId
                )
            )
        }
        return ids
    }

    /// The sidebar's top-level row ids including durable header-only groups.
    /// Empty-group identities are inserted in their stored position within the
    /// matching pin tier, so callers that plan against visible header rows can
    /// translate back to the live-tab row space without losing group slots.
    func sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
        promotingWorkspaceId promotedWorkspaceId: UUID? = nil
    ) -> [UUID] {
        let baseIds = sidebarTopLevelWorkspaceIds(promotingWorkspaceId: promotedWorkspaceId)
        return sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
            preservingTopLevelIds: baseIds
        )
    }

    /// Adds durable empty-group headers to a caller-provided live top-level
    /// order while preserving their stored position within each pin tier.
    ///
    /// Reorder and creation paths use this overload after they have computed a
    /// new live-row order. Keeping the insertion rule here ensures those paths
    /// cannot accidentally treat a header-only group as an omitted tail item.
    func sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
        preservingTopLevelIds baseIds: [UUID]
    ) -> [UUID] {
        let emptyGroups = workspaceGroups.filter(\.isEmpty)
        guard !emptyGroups.isEmpty else { return sidebarTierOrderedIds(baseIds) }

        let baseIdSet = Set(baseIds)
        var nextPinnedGroup: WorkspaceGroup?
        var nextUnpinnedGroup: WorkspaceGroup?
        var nextLiveSameTierByIndex: [WorkspaceGroup?] = Array(
            repeating: nil,
            count: workspaceGroups.count
        )
        for index in workspaceGroups.indices.reversed() {
            let group = workspaceGroups[index]
            nextLiveSameTierByIndex[index] = group.isPinned
                ? nextPinnedGroup
                : nextUnpinnedGroup
            guard !group.isEmpty else { continue }
            if group.isPinned {
                nextPinnedGroup = group
            } else {
                nextUnpinnedGroup = group
            }
        }

        var emptyBeforeAnchor: [UUID: [UUID]] = [:]
        var trailingPinned: [UUID] = []
        var trailingUnpinned: [UUID] = []
        for (index, group) in workspaceGroups.enumerated()
            where group.isEmpty && !baseIdSet.contains(group.anchorWorkspaceId) {
            if let nextGroup = nextLiveSameTierByIndex[index],
               baseIdSet.contains(nextGroup.anchorWorkspaceId) {
                emptyBeforeAnchor[nextGroup.anchorWorkspaceId, default: []]
                    .append(group.anchorWorkspaceId)
            } else if group.isPinned {
                trailingPinned.append(group.anchorWorkspaceId)
            } else {
                trailingUnpinned.append(group.anchorWorkspaceId)
            }
        }

        let tiers = sidebarOrderTiers()

        var ids: [UUID] = []
        ids.reserveCapacity(baseIds.count + emptyGroups.count)
        var emittedIds = Set<UUID>()
        for id in baseIds {
            for emptyId in emptyBeforeAnchor[id] ?? [] where emittedIds.insert(emptyId).inserted {
                ids.append(emptyId)
            }
            if emittedIds.insert(id).inserted {
                ids.append(id)
            }
        }
        if !trailingPinned.isEmpty {
            let firstLaterTierIndex = ids.firstIndex {
                (tiers[$0] ?? .workspace).rawValue > WorkspaceSidebarOrderTier.pinnedGroup.rawValue
            } ?? ids.count
            let inserted = trailingPinned.filter { emittedIds.insert($0).inserted }
            ids.insert(contentsOf: inserted, at: firstLaterTierIndex)
        }
        let firstWorkspaceIndex = ids.firstIndex { tiers[$0] == .workspace } ?? ids.count
        ids.insert(
            contentsOf: trailingUnpinned.filter { emittedIds.insert($0).inserted },
            at: firstWorkspaceIndex
        )
        return sidebarTierOrderedIds(ids)
    }

    /// Projects a desired full workspace-id order down to top-level row ids,
    /// appending any unmentioned workspaces in `tabs[]` order.
    func topLevelWorkspaceIdsPreservingOrder(_ desiredIds: [UUID]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)

        func appendTopLevelId(for id: UUID) {
            guard let tab = tabsById[id],
                  emittedWorkspaceIds.insert(tab.id).inserted else { return }
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }

        for id in desiredIds {
            appendTopLevelId(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendTopLevelId(for: tab.id)
        }
        return ids
    }

    /// The pinned subset of the top-level rows (pinned groups by group pin,
    /// ungrouped workspaces by workspace pin).
    func sidebarTopLevelPinnedWorkspaceIds(promotingWorkspaceId: UUID? = nil) -> Set<UUID> {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return Set(sidebarTopLevelWorkspaceIds(promotingWorkspaceId: promotingWorkspaceId).filter { id in
            topLevelWorkspaceIdIsPinned(id, tabsById: tabsById, groupsByAnchorId: groupsByAnchorId)
        })
    }

    /// The pinned subset of the top-level row ids including durable empty
    /// group headers.
    func sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups(
        promotingWorkspaceId: UUID? = nil
    ) -> Set<UUID> {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return Set(
            sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
                promotingWorkspaceId: promotingWorkspaceId
            ).filter { id in
                topLevelWorkspaceIdIsPinned(
                    id,
                    tabsById: tabsById,
                    groupsByAnchorId: groupsByAnchorId
                )
            }
        )
    }

    private func promotedTopLevelInsertionIndex(
        ids: [UUID],
        groupIndex: Int,
        promotedIsPinned: Bool,
        tabsById: [UUID: Tab],
        groupsByAnchorId: [UUID: WorkspaceGroup]
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: promotedIsPinned)
        var lowerBound = 0
        var sameTierCount = 0
        for id in ids {
            let group = groupsByAnchorId[id]
            let rowTier = WorkspaceSidebarOrderTier(
                isGroup: group != nil,
                isPinned: group?.isPinned ?? tabsById[id]?.isPinned ?? false
            )
            if rowTier.rawValue < tier.rawValue { lowerBound += 1 }
            if rowTier == tier { sameTierCount += 1 }
        }
        return min(max(desiredIndex, lowerBound), lowerBound + sameTierCount)
    }

    private func topLevelWorkspaceIdIsPinned(
        _ id: UUID,
        tabsById: [UUID: Tab],
        groupsByAnchorId: [UUID: WorkspaceGroup]
    ) -> Bool {
        if let group = groupsByAnchorId[id] {
            return group.isPinned
        }
        return tabsById[id]?.isPinned == true
    }

    /// Clamps a requested top-level reorder index into the mover's sidebar tier.
    func clampedTopLevelReorderIndex(
        forWorkspaceId workspaceId: UUID,
        targetIndex: Int,
        topLevelIds: [UUID]
    ) -> Int {
        let tiers = sidebarOrderTiers()
        let tier = tiers[workspaceId] ?? .workspace
        var lowerBound = 0
        var sameTierCount = 0
        for id in topLevelIds {
            let rowTier = tiers[id] ?? .workspace
            if rowTier.rawValue < tier.rawValue { lowerBound += 1 }
            if rowTier == tier { sameTierCount += 1 }
        }
        return min(max(targetIndex, lowerBound), max(lowerBound, lowerBound + sameTierCount - 1))
    }

    /// Helper for `normalizeWorkspaceGroupContiguity`: hoist the anchor to
    /// the front of its group's member list, then keep pinned member
    /// workspaces above unpinned member workspaces while preserving relative
    /// order inside each tier. No-op when the anchor isn't actually in the
    /// list (empty groups do not enter this member-run path).
    func anchorFirst(_ members: [Tab], anchorId: UUID) -> [Tab] {
        guard let anchorIndex = members.firstIndex(where: { $0.id == anchorId }) else {
            return members
        }
        let anchor = members[anchorIndex]
        let nonAnchors = members.filter { $0.id != anchorId }
        return [anchor] + nonAnchors.filter(\.isPinned) + nonAnchors.filter { !$0.isPinned }
    }

    /// Clamps a workspace into its group section or independent-workspace tier.
    func clampedReorderIndex(for workspace: Tab, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        if let groupClamp = clampedGroupedMemberReorderIndex(
            for: workspace,
            clampedTargetIndex: clamped
        ) {
            return groupClamp
        }
        let tiers = sidebarOrderTiers()
        let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: workspace.isPinned)
        var lowerBound = 0
        var sameTierCount = 0
        for tab in tabs {
            let rowTier = tiers[tab.id] ?? .workspace
            if rowTier.rawValue < tier.rawValue { lowerBound += 1 }
            if rowTier == tier { sameTierCount += 1 }
        }
        return min(max(clamped, lowerBound), min(lowerBound + sameTierCount - 1, tabs.count - 1))
    }

    /// The in-group clamp for any member workspace, including the stored
    /// anchor, or `nil` when the workspace is ungrouped.
    func clampedGroupedMemberReorderIndex(
        for workspace: Tab,
        clampedTargetIndex: Int
    ) -> Int? {
        guard let groupId = workspace.groupId,
              workspaceGroups.contains(where: { $0.id == groupId }) else {
            return nil
        }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.isPinned {
                count += 1
            }
        }
        let lowerBound = workspace.isPinned
            ? firstIndex
            : min(firstIndex + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount - 1, lowerBound)
            : lastIndex
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }

}
