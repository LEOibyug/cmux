public import Foundation
public import CmuxSettings
internal import OSLog

private let workspaceGroupLogger = Logger(subsystem: "com.cmuxterm.app", category: "WorkspaceGroupCoordinator")

/// Sequences every workspace-group flow over the window's `WorkspacesModel`:
/// group creation (member adoption or an empty generated anchor), member add/remove,
/// ungroup/delete, rename, collapse/pin/color/icon/anchor mutation, and
/// group-slot moves — lifted one-for-one from the legacy TabManager method
/// bodies. Workspace creation/teardown, selection moves, sidebar
/// multi-selection sync, localized strings, and settings reads invert
/// through `WorkspaceGroupHosting`.
@MainActor
public final class WorkspaceGroupCoordinator<Tab: WorkspaceTabRepresenting> {
    let model: WorkspacesModel<Tab>
    weak var host: (any WorkspaceGroupHosting<Tab>)?
    var deletingGroupIds = Set<UUID>()

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side host.
    public func attach(host: any WorkspaceGroupHosting<Tab>) {
        self.host = host
    }

    // MARK: - Creation

    /// Create a new group around the given child workspaces. Returns the new
    /// group id.
    ///
    /// When children are provided, the first child becomes the anchor and no
    /// workspace is created. All requested children must still exist; existing
    /// anchors can transfer without closing workspaces. Empty groups receive a
    /// generated anchor whose cwd defaults to `anchorWorkingDirectory` or the
    /// active workspace resolved by the host.
    @discardableResult
    public func createWorkspaceGroup(
        name: String,
        childWorkspaceIds: [UUID] = [],
        anchorWorkingDirectory: String? = nil,
        selectAnchor: Bool = true,
        collapseSidebarSelection: Bool = true,
        externalID: String? = nil
    ) -> UUID? {
        guard let host else { return nil }
        let trimmedExternalID = externalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExternalID = trimmedExternalID?.isEmpty == true ? nil : trimmedExternalID
        // The coordinator is main-actor isolated, so this lookup and the
        // insertion below form one atomic create-if-absent turn even when
        // several socket clients arrive concurrently. Names are deliberately
        // not consulted: a user may own multiple groups with the same name.
        if let normalizedExternalID,
           let existingGroup = model.workspaceGroups.first(where: { $0.externalID == normalizedExternalID }) {
            return existingGroup.id
        }
        let liveWorkspaceIds = Set(model.tabs.map(\.id))
        guard childWorkspaceIds.allSatisfy({ liveWorkspaceIds.contains($0) }) else { return nil }
        var seenChildIds = Set<UUID>()
        let eligibleChildren = childWorkspaceIds.filter { seenChildIds.insert($0).inserted }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? nextAutoWorkspaceGroupName()
            : trimmedName

        let firstChildTab = eligibleChildren.first.flatMap { firstId in
            model.tabs.first(where: { $0.id == firstId })
        }
        let inferredCwd: String? = anchorWorkingDirectory
            ?? firstChildTab?.currentDirectory
        let originalTabOrder = model.tabs.map(\.id)
        let previousGroupIds = Set(eligibleChildren.compactMap { workspaceId in
            model.tabs.first { $0.id == workspaceId }?.groupId
        })

        let anchorId: UUID
        let anchorProvenance: WorkspaceGroupAnchorProvenance
        let generatedAnchor: Tab?
        if let firstChildId = eligibleChildren.first {
            anchorId = firstChildId
            anchorProvenance = .user
            generatedAnchor = nil
        } else {
            guard let anchor = host.createGroupAnchorWorkspace(
                title: resolvedName,
                workingDirectory: inferredCwd,
                inheritWorkingDirectory: inferredCwd == nil,
                select: selectAnchor
            ) else { return nil }
            anchorId = anchor.id
            anchorProvenance = .generated
            generatedAnchor = anchor
        }

        let group = WorkspaceGroup(
            id: UUID(),
            name: resolvedName,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchorId,
            customColor: nil,
            iconSymbol: nil,
            externalID: normalizedExternalID,
            anchorWorkspaceProvenance: anchorProvenance
        )
        model.workspaceGroups.append(group)
        generatedAnchor?.groupId = group.id
        for id in eligibleChildren {
            model.assignGroup(workspaceId: id, groupId: group.id)
        }
        model.repairWorkspaceGroupAnchors(groupIds: previousGroupIds)
        if generatedAnchor == nil,
           selectAnchor,
           let anchor = model.tabs.first(where: { $0.id == anchorId }) {
            host.selectWorkspace(anchor)
        }
        placeNewWorkspaceGroupAtCreationPosition(
            groupId: group.id,
            anchorId: anchorId,
            childWorkspaceIds: eligibleChildren,
            originalTabOrder: originalTabOrder
        )
        // Collapse the sidebar multi-selection so a second ⌘⇧G press doesn't
        // immediately reuse the same child ids and create a duplicate group
        // around them. The new anchor is the only sensible "current"
        // selection at this point. Posts the hide notification so the
        // SwiftUI sidebar binding follows.
        //
        // Skipped for the non-focus socket/CLI path (caller passes
        // collapseSidebarSelection: false): per the socket focus policy in
        // CLAUDE.md, those entrypoints must not mutate the user's active
        // sidebar selection.
        if collapseSidebarSelection,
           !host.sidebarSelectedWorkspaceIds.isDisjoint(with: Set(eligibleChildren)) || host.sidebarSelectedWorkspaceIds.count > 1 {
            let hiddenIds = host.sidebarSelectedWorkspaceIds
            host.collapseSidebarSelectionForGroupCreation(
                hiddenWorkspaceIds: hiddenIds,
                anchorId: anchorId
            )
        }
        host.workspaceOrderDidChange(
            movedWorkspaceIds: [anchorId] + eligibleChildren.filter { $0 != anchorId }
        )
        return group.id
    }

    /// Create a brand-new workspace inheriting the anchor's cwd, attach it
    /// to the group, and position it within the group's tabs[] range per
    /// `placement`. Generated-purpose workspaces can keep a creation title as
    /// automatic metadata instead of adopting it as a user-owned custom title.
    /// Returns the new workspace.
    @discardableResult
    public func createWorkspaceInGroup(
        groupId: UUID,
        placement explicitPlacement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        title: String? = nil,
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        applyCreationTitleAsCustomTitle: Bool = true,
        inheritWorkingDirectory: Bool? = nil
    ) -> Tab? {
        guard let host else { return nil }
        // nil resolves to the stored global default at call time, matching the
        // legacy workspaceGroups.newWorkspacePlacement default-argument read.
        let placement = explicitPlacement
            ?? host.defaultNewWorkspacePlacementInGroup
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else { return nil }
        let originalTopLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
        let emptyHeaderId = group.isEmpty ? group.anchorWorkspaceId : nil
        let cwd = group.liveAnchorWorkspaceId
            .flatMap { anchorId in model.tabs.first(where: { $0.id == anchorId })?.currentDirectory }
        let workingDirectory = inheritWorkingDirectory == false ? nil : cwd
        guard let newWorkspace = host.createWorkspaceForGroup(
            title: title,
            workingDirectory: workingDirectory,
            initialSurface: initialSurface,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            inheritWorkingDirectory: inheritWorkingDirectory ?? (cwd == nil),
            select: select,
            applyCreationTitleAsCustomTitle: applyCreationTitleAsCustomTitle
        ) else { return nil }
        model.assignGroup(workspaceId: newWorkspace.id, groupId: groupId)
        var preferredTopLevelIds = originalTopLevelIds.filter { $0 != newWorkspace.id }
        if let emptyHeaderId,
           let slot = preferredTopLevelIds.firstIndex(of: emptyHeaderId) {
            preferredTopLevelIds[slot] = newWorkspace.id
        }
        placeWithinGroup(
            workspaceId: newWorkspace.id,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
        model.normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: preferredTopLevelIds
        )
        host.workspaceOrderDidChange(movedWorkspaceIds: [newWorkspace.id])
        return newWorkspace
    }

    /// Move an existing group member to the requested in-group slot. Called
    /// after `createWorkspaceInGroup` and any other path that needs to
    /// pin the new member relative to the group's members.
    private func placeWithinGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }),
              let currentIndex = model.tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let memberIndices = model.tabs.indices.filter { model.tabs[$0].groupId == groupId && model.tabs[$0].id != workspaceId }
        func logMissingPlacementAnchor(_ placementName: String) {
            workspaceGroupLogger.info(
                "workspaceGroup.placeWithinGroup missing placement anchor group=\(groupId.uuidString, privacy: .public) workspace=\(workspaceId.uuidString, privacy: .public) placement=\(placementName, privacy: .public)"
            )
        }
        let targetIndex: Int
        switch placement {
        case .afterCurrent:
            if let referenceWorkspaceId,
               referenceWorkspaceId != workspaceId,
               let referenceIndex = model.tabs.firstIndex(where: { $0.id == referenceWorkspaceId && $0.groupId == groupId }) {
                targetIndex = referenceIndex + 1
            } else if let anchorIndex = model.tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("afterCurrent")
                return
            }
        case .top:
            if let anchorIndex = model.tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                // Right after the anchor; the anchor stays first via
                // `normalizeWorkspaceGroupContiguity`'s anchorFirst pass.
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("top")
                return
            }
        case .end:
            if let lastMember = memberIndices.last {
                targetIndex = lastMember + 1
            } else {
                // Only the anchor and the new workspace exist; treat as top.
                if let anchorIndex = model.tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                    targetIndex = anchorIndex + 1
                } else {
                    logMissingPlacementAnchor("end")
                    return
                }
            }
        }
        guard currentIndex != targetIndex else { return }
        let insertAt = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        model.replaceTabs { currentTabs in
            var reordered = currentTabs
            let workspace = reordered.remove(at: currentIndex)
            let destination = max(0, min(insertAt, reordered.count))
            reordered.insert(workspace, at: destination)
            return reordered
        }
    }

    // MARK: - Membership

    /// Add an existing workspace to an existing group. Moving a source anchor
    /// promotes its first remaining member, or leaves an empty pinned group.
    /// No workspace is closed. If the workspace is currently selected and the
    /// target group is collapsed, the normal selection visibility rules apply.
    public func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }) else { return }
        guard let targetGroup = model.workspaceGroups.first(where: { $0.id == groupId }) else { return }
        guard tab.groupId != groupId else { return }
        let originalTopLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
        let emptyHeaderId = targetGroup.isEmpty ? targetGroup.anchorWorkspaceId : nil
        let previousGroupId = tab.groupId
        model.assignGroup(workspaceId: workspaceId, groupId: groupId)
        if let previousGroupId {
            model.repairWorkspaceGroupAnchors(groupIds: [previousGroupId])
        }
        let sourceAnchorId = previousGroupId.flatMap { previousGroupId in
            model.workspaceGroups.first(where: { $0.id == previousGroupId })?.anchorWorkspaceId
        }
        var preferredTopLevelIds = originalTopLevelIds.compactMap { id in
            id == workspaceId ? sourceAnchorId : id
        }
        if let emptyHeaderId,
           let slot = preferredTopLevelIds.firstIndex(of: emptyHeaderId) {
            preferredTopLevelIds[slot] = workspaceId
        }
        model.normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: preferredTopLevelIds
        )
        if let placement {
            placeWithinGroup(
                workspaceId: workspaceId,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
            model.normalizeWorkspaceGroupContiguity()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Detach only the requested workspace, including a stored anchor.
    /// Surviving source members retain their group; no workspace is closed.
    public func removeWorkspaceFromGroup(workspaceId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }),
              let groupId = tab.groupId else { return }
        model.assignGroup(workspaceId: workspaceId, groupId: nil)
        model.repairWorkspaceGroupAnchors(groupIds: [groupId])
        model.normalizeWorkspaceGroupContiguity()
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Removes an untouched generated anchor after its last real member closes.
    /// - Parameters:
    ///   - groupId: The group whose generated anchor may be removed.
    ///   - additionalMovedWorkspaceIds: Workspaces whose order changed with the cleanup.
    @discardableResult
    public func removeGeneratedAnchorIfOrphaned(
        groupId: UUID,
        additionalMovedWorkspaceIds: [UUID] = []
    ) -> Bool {
        guard let host,
              let group = model.workspaceGroups.first(where: { $0.id == groupId }),
              !deletingGroupIds.contains(groupId),
              group.anchorWorkspaceProvenance == .generated,
              !group.isPinned,
              let anchorId = group.liveAnchorWorkspaceId,
              let anchor = model.tabs.first(where: { $0.id == anchorId }),
              host.workspaceGroupGeneratedAnchorIsUntouched(anchor),
              !model.tabs.contains(where: { $0.groupId == groupId && $0.id != anchorId }) else {
            return false
        }
        guard case .removedGeneratedAnchor = removeGeneratedAnchorWorkspace(
            group: group,
            groupId: groupId,
            memberIds: [anchorId],
            additionalMovedWorkspaceIds: additionalMovedWorkspaceIds
        ) else {
            return false
        }
        return true
    }

    /// Dissolve a group without closing any workspace. Former members retain
    /// their relative order within their independent-workspace pin tiers.
    @discardableResult
    public func ungroupWorkspaceGroup(
        groupId: UUID,
        removeGeneratedAnchor: Bool = false
    ) -> WorkspaceGroupUngroupResult {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else {
            return .groupNotFound
        }
        let memberIds = model.tabs.filter { $0.groupId == groupId }.map(\.id)
        if removeGeneratedAnchor {
            return removeGeneratedAnchorWorkspace(group: group, groupId: groupId, memberIds: memberIds)
        }
        // An empty pinned group is durable state. Removing it through Ungroup
        // would bypass the explicit Delete Group action that owns its
        // confirmation; users can unpin it first if they want to flatten it.
        guard !memberIds.isEmpty || !group.isPinned else {
            return .emptyPinnedCannotUngroup
        }
        for id in memberIds {
            model.assignGroup(workspaceId: id, groupId: nil)
        }
        model.workspaceGroups.removeAll { $0.id == groupId }
        model.normalizeWorkspaceGroupContiguity()
        host?.workspaceOrderDidChange(movedWorkspaceIds: memberIds)
        return .dissolved(keptWorkspaceCount: memberIds.count)
    }

    /// Delete a group and close every workspace inside it (anchor + all
    /// members). This is the destructive sibling of
    /// `ungroupWorkspaceGroup`: ungroup keeps the workspaces, delete throws
    /// them away. Callers that need confirmation must prompt before calling
    /// this; the method itself is unconditional so socket/CLI paths can opt
    /// out of the prompt cleanly.
    @discardableResult
    public func deleteWorkspaceGroup(groupId: UUID, recordHistory: Bool = true) -> Int {
        guard let confirmation = deletionConfirmation(groupId: groupId) else { return 0 }
        return deleteWorkspaceGroup(confirmed: confirmation, recordHistory: recordHistory)
    }

    // MARK: - Group properties

    /// Rename only the group container. Workspace titles remain independently owned.
    public func renameWorkspaceGroup(groupId: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let group = model.workspaceGroups[index]
        guard group.name != trimmed else { return }
        model.workspaceGroups[index].name = trimmed
        host?.workspaceGroupNameDidChange()
    }

    /// UI-only collapse toggle: also moves focus to the anchor if the
    /// currently-selected workspace is a non-anchor child that would be
    /// hidden by the collapse. The pure-data variant
    /// `setWorkspaceGroupCollapsed` is the right call for socket/CLI paths
    /// that must preserve focus (the socket focus policy in CLAUDE.md).
    public func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let host else { return }
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let nextCollapsed = !model.workspaceGroups[index].isCollapsed
        if nextCollapsed {
            guard let anchorId = model.workspaceGroups[index].liveAnchorWorkspaceId else {
                setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
                return
            }
            if let selectedTabId = model.selectedTabId,
               selectedTabId != anchorId,
               let selectedTab = model.tabs.first(where: { $0.id == selectedTabId }),
               selectedTab.groupId == groupId,
               let anchor = model.tabs.first(where: { $0.id == anchorId }) {
                host.selectWorkspace(anchor)
            }
            // Strip any sidebar multi-selection entries that point at
            // now-hidden non-anchor children of this group. Without this, a
            // close/group shortcut fired after the collapse would still act
            // on workspaces the user can no longer see.
            let hiddenMemberIds: Set<UUID> = Set(
                model.tabs
                    .filter { $0.groupId == groupId && $0.id != anchorId }
                    .map(\.id)
            )
            if !hiddenMemberIds.isEmpty,
               !host.sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenMemberIds) {
                // Use the "did hide" event (not collapse-to-one) so the
                // SwiftUI sidebar only strips the hidden ids and keeps any
                // visible multi-selection entries that sit outside the group.
                // focusedWorkspaceId rides along only when focus moved.
                let focusedWorkspaceId: UUID? = (model.selectedTabId == anchorId) ? anchorId : nil
                host.subtractSidebarSelection(
                    hiddenWorkspaceIds: hiddenMemberIds,
                    focusedWorkspaceId: focusedWorkspaceId
                )
            }
        }
        setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
    }

    /// Pure data mutation — flips the collapse flag without touching
    /// selection. Use this from socket/CLI handlers so a non-focus-intent
    /// command never steals the user's active workspace.
    public func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].isCollapsed != isCollapsed else { return }
        model.workspaceGroups[index].isCollapsed = isCollapsed
    }

    /// Toggle the pinned state of a whole group. Pinned groups float above
    /// unpinned groups in the sidebar. Independent of per-workspace pin.
    public func toggleWorkspaceGroupPinned(groupId: UUID) {
        setWorkspaceGroupPinned(groupId: groupId, isPinned: !(model.workspaceGroups.first(where: { $0.id == groupId })?.isPinned ?? false))
    }

    /// Sets the group's pinned state and renormalizes the four sidebar tiers.
    public func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].isPinned != isPinned else { return }
        model.workspaceGroups[index].isPinned = isPinned
        model.normalizeWorkspaceGroupContiguity()
        let memberIds = model.tabs.filter { $0.groupId == groupId }.map(\.id)
        host?.workspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    /// Sets the group-level color override (hex string, nil clears).
    public func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].customColor != hex else { return }
        model.workspaceGroups[index].customColor = hex
    }

    /// Sets the group header icon (normalized through the host's symbol
    /// catalog); returns the normalized symbol.
    @discardableResult
    public func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.normalizedGroupIconSymbol(symbol)
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return nil }
        guard model.workspaceGroups[index].iconSymbol != normalized else { return normalized }
        model.workspaceGroups[index].iconSymbol = normalized
        return normalized
    }

    /// Reassign which member workspace serves as the group's anchor.
    /// `workspaceId` must already be a member of the group.
    public func setWorkspaceGroupAnchor(groupId: UUID, workspaceId: UUID) {
        guard let groupIndex = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }), tab.groupId == groupId else { return }
        guard model.workspaceGroups[groupIndex].liveAnchorWorkspaceId != workspaceId else { return }
        model.workspaceGroups[groupIndex].anchorWorkspaceId = workspaceId
        model.workspaceGroups[groupIndex].anchorWorkspaceProvenance = .user
        // Hoist the new anchor to the front of its members in tabs[] so the
        // sidebar header is rendered at the anchor's position. Without this,
        // the header would still draw at the (former) first member but the
        // shortcut digit / focus target would point at the new anchor lower
        // down, breaking workspace-number navigation.
        model.normalizeWorkspaceGroupContiguity()
        // Publish the order change so CmuxEventBus subscribers and any
        // notification observers see the new anchor position immediately
        // (other group-mutation paths post; this one was a hole).
        let memberIds = model.tabs.filter { $0.groupId == groupId }.map(\.id)
        host?.workspaceOrderDidChange(movedWorkspaceIds: memberIds.isEmpty ? [workspaceId] : memberIds)
        _ = tab
    }

    // MARK: - Group slots

    /// Move a group to a new group-slot position. `targetIndex` is interpreted
    /// as the FINAL position the group should end up at in `workspaceGroups`
    /// (post-move). It is clamped to the range occupied by groups in the same
    /// pin tier as the source. Ungrouped top-level workspace rows keep their
    /// slots; the reordered group anchors are projected back into the existing
    /// group slots.
    public func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        guard moveWorkspaceGroupSlot(groupId: groupId, toIndex: targetIndex) else { return }
        applyWorkspaceGroupSlotOrderToTabs()
        let memberIds = model.tabs.filter { $0.groupId == groupId }.map(\.id)
        host?.workspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    @discardableResult
    private func moveWorkspaceGroupSlot(groupId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return false }
        let isPinned = model.workspaceGroups[currentIndex].isPinned
        let sameTierIndices = model.workspaceGroups.indices.filter { model.workspaceGroups[$0].isPinned == isPinned }
        guard let firstSameTier = sameTierIndices.first,
              let lastSameTier = sameTierIndices.last else { return false }
        let clampedTarget = max(firstSameTier, min(targetIndex, lastSameTier))
        guard clampedTarget != currentIndex else { return false }
        let group = model.workspaceGroups.remove(at: currentIndex)
        // Insert at clampedTarget directly — the source's removal already
        // shifted subsequent indices down, so for a desired final position
        // of N: if N < currentIndex, indices to the left didn't move (insert
        // at N); if N > currentIndex, the source's removal shifted N's old
        // contents left by one, but we want our group AT position N in the
        // final array, which means inserting after that element — index N
        // works because we're inserting into a shorter array.
        model.workspaceGroups.insert(group, at: max(0, min(clampedTarget, model.workspaceGroups.count)))
        return true
    }

    private func applyWorkspaceGroupSlotOrderToTabs() {
        let groupAnchorIds = model.workspaceGroups.map(\.anchorWorkspaceId)
        let independentIds = model.tabs.filter { $0.groupId == nil }.map(\.id)
        model.normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: groupAnchorIds + independentIds
        )
    }

    // MARK: - Creation placement

    /// Pick the next "Group N" name that doesn't collide with an existing
    /// group. Used when the user creates a group without naming it. The
    /// localized format comes from the host (String(localized:) stays
    /// app-side).
    private func nextAutoWorkspaceGroupName() -> String {
        let used = Set(model.workspaceGroups.map(\.name))
        var n = model.workspaceGroups.count + 1
        while true {
            let format = host?.localizedAutoGroupNameFormat ?? "Group %lld"
            let candidate = String.localizedStringWithFormat(format, n)
            if !used.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Place a freshly-created group at its first child's position, clamped
    /// into the regular-group tier. Existing rows keep their same-tier order.
    private func placeNewWorkspaceGroupAtCreationPosition(
        groupId: UUID,
        anchorId: UUID,
        childWorkspaceIds: [UUID],
        originalTabOrder: [UUID]
    ) {
        let childIdSet = Set(childWorkspaceIds)
        let orderedChildIds = originalTabOrder.filter {
            childIdSet.contains($0) && $0 != anchorId
        }
        guard !childWorkspaceIds.isEmpty,
              let insertionIndex = originalTabOrder.firstIndex(where: { childIdSet.contains($0) }) else {
            model.normalizeWorkspaceGroupContiguity()
            return
        }

        var desiredIds: [UUID] = []
        desiredIds.reserveCapacity(model.tabs.count)
        for (index, id) in originalTabOrder.enumerated() {
            if index == insertionIndex {
                desiredIds.append(anchorId)
                desiredIds.append(contentsOf: orderedChildIds)
            }
            if !childIdSet.contains(id) {
                desiredIds.append(id)
            }
        }
        model.normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: model.topLevelWorkspaceIdsPreservingOrder(desiredIds)
        )
        if model.workspaceGroups.contains(where: { $0.id == groupId }) {
            model.syncWorkspaceGroupsOrderToAnchorOrder()
        }
    }
}
