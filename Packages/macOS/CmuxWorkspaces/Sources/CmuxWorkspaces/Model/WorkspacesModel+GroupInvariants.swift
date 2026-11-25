public import Foundation

// Group-section invariant maintenance over the model's own tabs/groups
// storage, lifted one-for-one from the legacy private TabManager helpers:
// contiguous group runs, anchor-first member order, four sidebar tiers,
// and the group-anchor lifecycle bound to anchor removal.
extension WorkspacesModel {
    /// Sets a workspace's group membership and preserves selected-row visibility.
    func assignGroup(workspaceId: UUID, groupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.groupId != groupId else { return }
        tab.groupId = groupId
        if let groupId,
           let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[groupIndex].liveAnchorWorkspaceId == nil {
            // The first workspace added to an empty pinned group becomes its
            // live header anchor. The placeholder identity is retained only
            // while the group has no members.
            workspaceGroups[groupIndex].anchor = .workspace(workspaceId)
            workspaceGroups[groupIndex].anchorWorkspaceProvenance = .user
        }
        if selectedTabId == workspaceId {
            expandWorkspaceGroupForSelectionIfNeeded()
        }
    }

    /// Preserve source containers after transfers without closing any workspace.
    /// Sidebar member reorders may also promote the first member in their new
    /// order so the internal anchor does not override the requested row order.
    func repairWorkspaceGroupAnchors(
        groupIds: Set<UUID>,
        preferringFirstMemberIn preferredGroupIds: Set<UUID> = []
    ) {
        guard !groupIds.isEmpty else { return }
        var firstMemberIds: [UUID: UUID] = [:]
        var remainingGroupIdsByWorkspaceId: [UUID: UUID] = [:]
        for tab in tabs {
            guard let groupId = tab.groupId, groupIds.contains(groupId) else { continue }
            if firstMemberIds[groupId] == nil {
                firstMemberIds[groupId] = tab.id
            }
            remainingGroupIdsByWorkspaceId[tab.id] = groupId
        }
        for index in workspaceGroups.indices {
            let group = workspaceGroups[index]
            guard groupIds.contains(group.id) else { continue }
            if let anchorId = group.liveAnchorWorkspaceId,
               remainingGroupIdsByWorkspaceId[anchorId] == group.id,
               !preferredGroupIds.contains(group.id) || firstMemberIds[group.id] == anchorId {
                continue
            }
            if let firstMemberId = firstMemberIds[group.id] {
                workspaceGroups[index].anchor = .workspace(firstMemberId)
                workspaceGroups[index].anchorWorkspaceProvenance = .user
            } else {
                workspaceGroups[index].anchor = .empty(group.id)
                workspaceGroups[index].anchorWorkspaceProvenance = .unknown
            }
        }
        workspaceGroups.removeAll {
            groupIds.contains($0.id) && $0.isEmpty && !$0.isPinned
        }
    }

    /// Apply a desired workspace order as contiguous, anchor-first group runs,
    /// stably partitioned into the four sidebar tiers. Direct mutation callers
    /// share the same invariant as top-level normalization.
    func normalizeWorkspaceGroupRunsPreservingOrder(_ desiredIds: [UUID]) {
        let repairedAnchors = repairWorkspaceGroupMembershipAndAnchors()
        tabs = sidebarOrderedWorkspaces(preserving: desiredIds.map { repairedAnchors[$0] ?? $0 })
    }

    /// Restore/import may set membership directly or retain a stale anchor.
    /// Repair before projecting rows so a missing anchor cannot move its group.
    private func repairWorkspaceGroupMembershipAndAnchors() -> [UUID: UUID] {
        let knownGroupIds = Set(workspaceGroups.map(\.id))
        var firstMemberIds: [UUID: UUID] = [:]
        var groupIdsByWorkspaceId: [UUID: UUID] = [:]
        for tab in tabs {
            guard let groupId = tab.groupId else { continue }
            guard knownGroupIds.contains(groupId) else {
                tab.groupId = nil
                continue
            }
            if firstMemberIds[groupId] == nil { firstMemberIds[groupId] = tab.id }
            groupIdsByWorkspaceId[tab.id] = groupId
        }
        var repairedAnchors: [UUID: UUID] = [:]
        for index in workspaceGroups.indices {
            let group = workspaceGroups[index]
            if let anchorId = group.liveAnchorWorkspaceId,
               groupIdsByWorkspaceId[anchorId] == group.id { continue }
            if let firstMemberId = firstMemberIds[group.id] {
                workspaceGroups[index].anchor = .workspace(firstMemberId)
                workspaceGroups[index].anchorWorkspaceProvenance = .user
            } else {
                workspaceGroups[index].anchor = .empty(group.id)
                workspaceGroups[index].anchorWorkspaceProvenance = .unknown
            }
            let anchorId = workspaceGroups[index].anchorWorkspaceId
            if anchorId != group.anchorWorkspaceId {
                repairedAnchors[group.anchorWorkspaceId] = anchorId
            }
        }
        return repairedAnchors
    }

    /// Reorder `tabs` so groups stay contiguous and anchor-first, preserving
    /// relative row order within pinned groups, pinned independent workspaces,
    /// regular groups, and regular independent workspaces, in that order.
    ///
    /// Within each group, members keep their relative order. A group anchor is
    /// the group's top-level row for ordering purposes.
    public func normalizeWorkspaceGroupContiguity(
        preservingTopLevelIds preferredTopLevelIds: [UUID]? = nil
    ) {
        let repairedAnchors = repairWorkspaceGroupMembershipAndAnchors()
        let topLevelIds: [UUID]
        if let preferredTopLevelIds {
            // Callers usually compute this order from live tabs only. Reinsert
            // durable header-only groups before normalizing so an omitted
            // placeholder cannot be appended to the tail by the group-order
            // reconciliation below.
            topLevelIds = sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
                preservingTopLevelIds: preferredTopLevelIds.map { repairedAnchors[$0] ?? $0 }
            )
        } else {
            topLevelIds = sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
        }
        // Always reassign so SwiftUI consumers re-evaluate row modifiers that
        // depend on `Workspace.groupId` even when the array contents are
        // unchanged.
        tabs = sidebarOrderedWorkspaces(preserving: topLevelIds)
        syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: topLevelIds)
    }

    /// Ensure the group containing the newly-selected workspace is expanded, so the
    /// selected row is actually visible in the sidebar. Called from `selectedTabId`'s
    /// didSet hook. No-op when the workspace is ungrouped or its group is already expanded.
    public func expandWorkspaceGroupForSelectionIfNeeded() {
        guard let selectedTabId,
              let groupId = tabs.first(where: { $0.id == selectedTabId })?.groupId,
              let index = workspaceGroups.firstIndex(where: { $0.id == groupId }),
              workspaceGroups[index].isCollapsed else {
            return
        }
        // The anchor is the group header's visible representation, so
        // focusing it doesn't hide it. Skip auto-expand when the focused
        // workspace IS the group's anchor — that lets users work in the
        // anchor while keeping the rest of the group folded away.
        guard workspaceGroups[index].anchorWorkspaceId != selectedTabId else { return }
        workspaceGroups[index].isCollapsed = false
    }

    /// Reorder `workspaceGroups` so each group's relative position matches
    /// the order its anchor occupies in `tabs[]`. Call this after an anchor
    /// reorder so later group-slot commands observe the same order the user
    /// sees in the sidebar.
    func syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: [UUID]? = nil) {
        let topLevelIds = preferredTopLevelIds ?? sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        var groupsByTier = Array(repeating: [WorkspaceGroup](), count: WorkspaceSidebarOrderTier.allCases.count)
        var emittedGroupIds = Set<UUID>()
        func appendGroup(_ group: WorkspaceGroup) {
            guard emittedGroupIds.insert(group.id).inserted else { return }
            let tier = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned)
            groupsByTier[tier.rawValue].append(group)
        }
        for id in topLevelIds {
            if let group = groupsByAnchorId[id] { appendGroup(group) }
        }
        for group in workspaceGroups { appendGroup(group) }
        workspaceGroups = groupsByTier.flatMap { $0 }
    }

    /// Hoist promoted (non-anchor) members to the front of their group's
    /// member run, right after the anchor, preserving each group's position.
    func moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [UUID]) {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var promotedIdsByGroupId: [UUID: [UUID]] = [:]
        for workspaceId in workspaceIds {
            guard let tab = tabsById[workspaceId],
                  let groupId = tab.groupId,
                  let group = groupsById[groupId],
                  tab.id != group.anchorWorkspaceId else {
                continue
            }
            promotedIdsByGroupId[groupId, default: []].append(workspaceId)
        }
        guard !promotedIdsByGroupId.isEmpty else { return }

        var replacementMembersByGroupId: [UUID: [Tab]] = [:]
        for (groupId, promotedIds) in promotedIdsByGroupId {
            guard let group = groupsById[groupId] else { continue }
            let orderedMembers = anchorFirst(
                tabs.filter { $0.groupId == groupId },
                anchorId: group.anchorWorkspaceId
            )
            guard let anchor = orderedMembers.first(where: { $0.id == group.anchorWorkspaceId }) else { continue }
            var emittedPromotedIds = Set<UUID>()
            let promotedMembers = promotedIds.compactMap { id -> Tab? in
                guard emittedPromotedIds.insert(id).inserted else { return nil }
                return tabsById[id]
            }
            let promotedIdSet = Set(promotedMembers.map(\.id))
            let remainingMembers = orderedMembers.filter {
                $0.id != group.anchorWorkspaceId && !promotedIdSet.contains($0.id)
            }
            replacementMembersByGroupId[groupId] = [anchor] + promotedMembers + remainingMembers
        }
        guard !replacementMembersByGroupId.isEmpty else { return }

        var emittedGroupIds = Set<UUID>()
        var reordered: [Tab] = []
        reordered.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let replacementMembers = replacementMembersByGroupId[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    reordered.append(contentsOf: replacementMembers)
                }
            } else {
                reordered.append(tab)
            }
        }
        tabs = reordered
    }

    /// Applies the detach-path lifecycle for groups anchored by a removed
    /// workspace. Unpinned groups dissolve as before; pinned groups retain
    /// their membership, promote a remaining member, or become an empty group.
    /// Caller is responsible for having already removed the workspace from
    /// `tabs`.
    public func dissolveGroupsAnchoredBy(closedWorkspaceId: UUID) {
        let affectedGroups = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
        guard !affectedGroups.isEmpty else { return }
        let dissolvedGroupIds = affectedGroups.filter { !$0.isPinned }.map(\.id)
        for group in affectedGroups where group.isPinned {
            guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == group.id }) else { continue }
            if let nextAnchor = tabs.first(where: { $0.groupId == group.id }) {
                workspaceGroups[groupIndex].anchor = .workspace(nextAnchor.id)
                workspaceGroups[groupIndex].anchorWorkspaceProvenance = .user
            } else {
                workspaceGroups[groupIndex].anchor = .empty(group.id)
                workspaceGroups[groupIndex].anchorWorkspaceProvenance = .unknown
            }
        }
        for gid in dissolvedGroupIds {
            for tab in tabs where tab.groupId == gid {
                tab.groupId = nil
            }
        }
        workspaceGroups.removeAll { dissolvedGroupIds.contains($0.id) }
        // Newly-ungrouped members may be sitting above other groups, which
        // violates the renderer's pinned-solo / pinned-groups / unpinned-
        // groups / ungrouped-unpinned ordering invariant. Renormalize so
        // they slide into the ungrouped tier at the bottom.
        normalizeWorkspaceGroupContiguity()
    }

    /// Close-path group fixup for when `closedWorkspaceId` was a group anchor.
    ///
    /// Unlike `dissolveGroupsAnchoredBy` (used by the cross-window detach
    /// path), closing a workspace affects only that one workspace: the group
    /// survives by promoting its earliest remaining member (in `tabs` order)
    /// to be the new anchor. A pinned group with no members transitions to an
    /// empty anchor; an unpinned group is removed. Caller is responsible for
    /// having already removed the closed workspace from `tabs`.
    ///
    /// Returns the workspace ids promoted to anchor. A promoted workspace's
    /// resolved display title switches from its own title to the group name,
    /// so the caller must invalidate any imperatively-cached title chrome
    /// (window title, toolbar label) for a promoted anchor that is selected.
    @discardableResult
    public func promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: UUID) -> [UUID] {
        let affectedGroupIds = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
            .map(\.id)
        guard !affectedGroupIds.isEmpty else { return [] }
        var promotedAnchorIds: [UUID] = []
        var removedGroupIds: [UUID] = []
        for gid in affectedGroupIds {
            guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == gid }) else { continue }
            if let nextAnchor = tabs.first(where: { $0.groupId == gid }) {
                workspaceGroups[groupIndex].anchorWorkspaceId = nextAnchor.id
                workspaceGroups[groupIndex].anchorWorkspaceProvenance = .user
                promotedAnchorIds.append(nextAnchor.id)
            } else if workspaceGroups[groupIndex].isPinned {
                workspaceGroups[groupIndex].anchor = .empty(workspaceGroups[groupIndex].id)
                workspaceGroups[groupIndex].anchorWorkspaceProvenance = .unknown
            } else {
                removedGroupIds.append(gid)
            }
        }
        if !removedGroupIds.isEmpty {
            workspaceGroups.removeAll { removedGroupIds.contains($0.id) }
        }
        // Hoist each promoted anchor to the front of its members so the sidebar
        // header renders at the anchor's row (parity with setWorkspaceGroupAnchor).
        normalizeWorkspaceGroupContiguity()
        return promotedAnchorIds
    }
}
