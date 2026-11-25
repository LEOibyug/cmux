import CmuxWorkspaces
import Foundation

/// Stable value identity for one drawable item in the workspace sidebar.
///
/// Keep live `Workspace` / `WorkspaceGroup` references out of this value. A
/// `LazyVStack` copies and diffs its `ForEach` data while placing rows; carrying
/// the models through that path made scrolling copy the live sidebar graph and
/// blurred the ownership boundary between layout data and observed state.
/// Models are resolved from the parent-owned render context only when SwiftUI
/// asks to realize a row.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID, anchorWorkspaceId: UUID)
    case workspace(workspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        }
    }

    var rowId: UUID {
        switch self {
        case .groupHeader(let groupId, _):
            return groupId
        case .workspace(let workspaceId):
            return workspaceId
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup]? = nil,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty || !groupsById.isEmpty else { return [] }
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: groupsById)
        let memberIdsByGroupId = memberWorkspaceIdsByGroupId(
            tabs: tabs,
            groupsById: groupsById,
            effectiveMembership: effectiveMembershipByWorkspaceId
        )
        let ordered = orderedGroups
            ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let tierCount = WorkspaceSidebarOrderTier.allCases.count
        var nextLiveGroupByTier: [UUID?] = Array(repeating: nil, count: tierCount)
        var emptyBeforeGroup: [UUID: [WorkspaceGroup]] = [:]
        var trailingEmptyByTier: [[WorkspaceGroup]] = Array(repeating: [], count: tierCount)
        for orderedGroup in ordered.reversed() {
            guard let group = groupsById[orderedGroup.id] else { continue }
            let tier = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned).rawValue
            if memberIdsByGroupId[group.id] != nil {
                nextLiveGroupByTier[tier] = group.id
            } else if group.isEmpty {
                // Only durable empty groups get header-only rows. A nonempty
                // group with a stale anchor must not become a ghost header.
                if let nextLiveGroupId = nextLiveGroupByTier[tier] {
                    emptyBeforeGroup[nextLiveGroupId, default: []].append(group)
                } else {
                    trailingEmptyByTier[tier].append(group)
                }
            }
        }

        var itemsByTier: [[SidebarWorkspaceRenderItem]] = Array(repeating: [], count: tierCount)
        var emittedHeaders: Set<UUID> = []
        for tab in tabs {
            // Group blocks follow their first member's position within their
            // tier, even while restored tabs temporarily contain split runs.
            // The group's pin state owns the whole block, not its members'.
            if let groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil,
               let group = groupsById[groupId] {
                guard emittedHeaders.insert(groupId).inserted else { continue }
                let tier = WorkspaceSidebarOrderTier(isGroup: true, isPinned: group.isPinned).rawValue
                for emptyGroup in emptyBeforeGroup[groupId, default: []].reversed() {
                    itemsByTier[tier].append(.groupHeader(
                        groupId: emptyGroup.id,
                        anchorWorkspaceId: emptyGroup.anchorWorkspaceId
                    ))
                }
                itemsByTier[tier].append(.groupHeader(
                    groupId: group.id,
                    anchorWorkspaceId: group.anchorWorkspaceId
                ))
                if !group.isCollapsed {
                    for workspaceId in memberIdsByGroupId[groupId, default: []] {
                        itemsByTier[tier].append(.workspace(workspaceId: workspaceId))
                    }
                }
            } else {
                let tier = WorkspaceSidebarOrderTier(isGroup: false, isPinned: tab.isPinned).rawValue
                itemsByTier[tier].append(.workspace(workspaceId: tab.id))
            }
        }

        var rendered: [SidebarWorkspaceRenderItem] = []
        rendered.reserveCapacity(tabs.count + groupsById.count)
        for tier in WorkspaceSidebarOrderTier.allCases {
            rendered.append(contentsOf: itemsByTier[tier.rawValue])
            for group in trailingEmptyByTier[tier.rawValue].reversed() {
                rendered.append(.groupHeader(
                    groupId: group.id,
                    anchorWorkspaceId: group.anchorWorkspaceId
                ))
            }
        }
        return rendered
    }

    /// Workspace ids represented by ordinary rows, in their rendered order.
    ///
    /// Group headers represent their anchor workspace for interaction, but are
    /// containers rather than numbered workspace rows.
    static func numberedWorkspaceIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
    }

    static func numberedWorkspaceIndexById(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(renderItems.count)
        for item in renderItems {
            guard case .workspace(let workspaceId) = item else { continue }
            result[workspaceId] = result.count
        }
        return result
    }

    static func numberedWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        numberedWorkspaceIds(from: renderItems(tabs: tabs, groupsById: groupsById))
    }

    static func memberWorkspaceIdsByGroupId(tabs: [Workspace]) -> [UUID: [UUID]] {
        memberWorkspaceIdsByGroupId(tabs: tabs, groupsById: nil)
    }

    /// Returns the group membership that is safe for sidebar rendering.
    ///
    /// A workspace may carry a stale group id after a restore or an
    /// in-flight anchor promotion. Only groups with a live anchor (or an
    /// explicitly empty durable anchor) are renderable; all other references
    /// become root-level rows. A live anchor also wins when its workspace's
    /// copied `groupId` is temporarily nil, keeping the header and member rows
    /// on one authoritative group run.
    static func effectiveGroupIdByWorkspaceId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID: UUID?] {
        let liveWorkspaceIds = Set(tabs.map(\.id))
        let renderableGroupIds = Set(groupsById.values.compactMap { group in
            if group.isEmpty { return group.id }
            guard let liveAnchorId = group.liveAnchorWorkspaceId,
                  liveWorkspaceIds.contains(liveAnchorId) else {
                return nil
            }
            return group.id
        })
        let groupIdByLiveAnchor = groupsById.values
            .filter { renderableGroupIds.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .reduce(into: [UUID: UUID]()) { result, group in
                guard let liveAnchorId = group.liveAnchorWorkspaceId,
                      result[liveAnchorId] == nil else { return }
                result[liveAnchorId] = group.id
            }
        return Dictionary(uniqueKeysWithValues: tabs.map { tab in
            let effectiveGroupId = groupIdByLiveAnchor[tab.id]
                ?? tab.groupId.flatMap { renderableGroupIds.contains($0) ? $0 : nil }
            return (tab.id, effectiveGroupId)
        })
    }

    /// Builds the member index using effective, renderable group membership.
    static func memberWorkspaceIdsByGroupId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]?,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? groupsById.map { effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: $0) }
        for tab in tabs {
            let groupId: UUID?
            if let effectiveMembershipByWorkspaceId {
                groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil
            } else {
                groupId = tab.groupId
            }
            if let groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}
