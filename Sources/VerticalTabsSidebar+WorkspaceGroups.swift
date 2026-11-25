import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxFoundation
import CmuxNotifications
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    private static func workspaceGroupRunningCount(
        memberWorkspaceIds: [UUID],
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput]
    ) -> Int {
        memberWorkspaceIds.reduce(0) { total, workspaceId in
            total + (workspaceRowsById[workspaceId]?.workspace.runningAgentCount ?? 0)
        }
    }

    private static func workspaceGroupActivity(
        runningCount: Int,
        memberWorkspaceIds: [UUID],
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> SidebarWorkspaceGroupActivity {
        SidebarWorkspaceGroupActivity(
            runningCount: runningCount,
            unreadCount: memberWorkspaceIds.reduce(0) {
                $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1)
            }
        )
    }

    func sidebarWorkspaceGroupTableConfiguration(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        memberStatusGlyphs: [UUID: SidebarCompactStatusGlyph.GroupMember],
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput],
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let settings = renderContext.tabItemSettings
        let liveAnchorId = group.liveAnchorWorkspaceId
        let dragIdentity = group.id
        let isAnchorActive = group.isCollapsed
            && (tabManager.selectedTabId.map { memberWorkspaceIds.contains($0) } ?? false)
        let isMultiSelected = group.isCollapsed && selectedTabIds.count > 1
            && memberWorkspaceIds.contains(where: selectedTabIds.contains)
        let anchorCwd = liveAnchorId.flatMap { renderContext.workspaceById[$0]?.currentDirectory }
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let multiSelectionBackgroundStyle = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: false,
            isMultiSelected: true,
            customColorHex: effectiveColor,
            colorScheme: renderContext.environment.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex,
            subtleSelection: settings.subtleSelection,
            brightenInDarkMode: settings.brightenInDarkMode,
            unselectedFillOpacity: settings.unselectedFillOpacity,
            increaseContrast: renderContext.environment.displayAccessibility.increaseContrast,
            accent: settings.accentColor
        )
        let anchorActiveEdgeColor = sidebarGroupHeaderAnchorActiveEdgeNSColor(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            subtleSelection: settings.subtleSelection,
            sidebarSelectionColorHex: settings.selectionColorHex,
            colorScheme: renderContext.environment.colorScheme,
            increaseContrast: renderContext.environment.displayAccessibility.increaseContrast
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        // The AppKit controller applies the current unread snapshot after row
        // construction, keeping this root projection outside Observation.
        let unreadSnapshot = SidebarUnreadSnapshot()
        let runningCount = Self.workspaceGroupRunningCount(
            memberWorkspaceIds: memberWorkspaceIds,
            workspaceRowsById: workspaceRowsById
        )
        let activity = Self.workspaceGroupActivity(
            runningCount: runningCount,
            memberWorkspaceIds: memberWorkspaceIds,
            unreadSnapshot: unreadSnapshot
        )
        // The tooltip leads with the notification text only where rows show it.
        let showsNotificationMessage = settings.showsNotificationMessage
        let statusGlyph = SidebarCompactStatusGlyph.groupHeader(
            isCollapsed: group.isCollapsed,
            anchorId: liveAnchorId,
            memberIds: memberWorkspaceIds,
            members: memberStatusGlyphs,
            unread: { (unreadSnapshot.unreadCount(forWorkspaceId: $0), showsNotificationMessage ? unreadSnapshot.summary(forWorkspaceId: $0).latestNotificationText : nil) }
        )
        let anchorIds = liveAnchorId.map { [$0] } ?? []
        let canMarkAnchorRead = unreadSnapshot.canMarkWorkspaceRead(forWorkspaceIds: anchorIds)
        let canMarkAnchorUnread = unreadSnapshot.canMarkWorkspaceUnread(forWorkspaceIds: anchorIds)
        let anchorHasLatestNotification = liveAnchorId.map {
            unreadSnapshot.summary(forWorkspaceId: $0).hasLatestNotification
        } ?? false
        let canMarkAllRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: memberWorkspaceIds
        )
        let canMarkAllUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: memberWorkspaceIds
        )
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: group.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: group.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        let hasVisibleMembers = !group.isCollapsed && !memberWorkspaceIds.isEmpty
        let model = SidebarGroupHeaderRowModel(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            anchorActiveEdgeColor: anchorActiveEdgeColor,
            memberCount: memberWorkspaceIds.count,
            activity: activity,
            hasVisibleMembers: hasVisibleMembers,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            statusGlyph: statusGlyph,
            shortcutHintText: nil,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            globalFontMagnificationPercent: renderContext.environment.globalFontMagnificationPercent,
            cwdContextMenuItems: cwdContextMenuItems,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.id,
            isBeingDragged: dragState.draggedTabId == dragIdentity,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            colorSchemeIsDark: renderContext.environment.colorScheme == .dark,
            notificationBadgeColorHex: settings.notificationBadgeColorHex,
            accentColor: settings.accentColor
        )
        let actions = makeWorkspaceGroupHeaderActions(
            groupId: group.id,
            fallbackGroupName: group.name,
            fallbackAnchorWorkspaceId: group.anchorWorkspaceId,
            placement: newWorkspacePlacement,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        return SidebarWorkspaceTableRowConfiguration(
            groupHeaderModel: model,
            actions: actions,
            environment: renderContext.environment,
            unreadDependencyWorkspaceIds: Set(memberWorkspaceIds)
                .union(liveAnchorId.map { [$0] } ?? []),
            unreadRebuild: {
                [model, liveAnchorId, runningCount,
                 isCollapsed = group.isCollapsed, memberWorkspaceIds,
                 memberStatusGlyphs, showsNotificationMessage] snapshot in
                // Membership and collapse are structural row inputs, so their
                // changes rebuild this configuration. Reuse the render context's
                // indexed members instead of rescanning every tab per unread row.
                var fresh = model
                fresh.hasVisibleMembers = hasVisibleMembers
                fresh.activity = Self.workspaceGroupActivity(
                    runningCount: runningCount,
                    memberWorkspaceIds: memberWorkspaceIds,
                    unreadSnapshot: snapshot
                )
                fresh.canMarkRead = snapshot.canMarkWorkspaceRead(
                    forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
                )
                fresh.canMarkUnread = snapshot.canMarkWorkspaceUnread(
                    forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
                )
                fresh.hasLatestNotifications = liveAnchorId.map {
                    snapshot.summary(forWorkspaceId: $0).hasLatestNotification
                } ?? false
                fresh.canMarkAllRead = snapshot.canMarkWorkspaceRead(
                    forWorkspaceIds: memberWorkspaceIds
                )
                fresh.canMarkAllUnread = snapshot.canMarkWorkspaceUnread(
                    forWorkspaceIds: memberWorkspaceIds
                )
                fresh.statusGlyph = SidebarCompactStatusGlyph.groupHeader(
                    isCollapsed: isCollapsed,
                    anchorId: liveAnchorId,
                    memberIds: memberWorkspaceIds,
                    members: memberStatusGlyphs,
                    unread: { (snapshot.unreadCount(forWorkspaceId: $0), showsNotificationMessage ? snapshot.summary(forWorkspaceId: $0).latestNotificationText : nil) }
                )
                return fresh
            }
        )
    }

    func sidebarWorkspaceGroupRowSnapshot(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        memberStatusGlyphs: [UUID: SidebarCompactStatusGlyph.GroupMember],
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput],
        unreadSnapshot: SidebarUnreadSnapshot,
        notificationIndex: SidebarWorkspaceNotificationIndex,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> SidebarWorkspaceGroupRowSnapshot {
        let unreadSummariesByWorkspaceId = unreadSnapshot.summaryByWorkspaceId
        let settings = renderContext.tabItemSettings
        let liveAnchorId = group.liveAnchorWorkspaceId
        let dragIdentity = group.id
        let isAnchorActive = selection == .tabs && group.isCollapsed
            && (tabManager.selectedTabId.map { memberWorkspaceIds.contains($0) } ?? false)
        let isMultiSelected = selection == .tabs && group.isCollapsed && selectedTabIds.count > 1
            && memberWorkspaceIds.contains(where: selectedTabIds.contains)
        let anchorCwd = liveAnchorId.flatMap { renderContext.workspaceById[$0]?.currentDirectory }
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let multiSelectionBackgroundStyle = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: false,
            isMultiSelected: true,
            customColorHex: effectiveColor,
            colorScheme: renderContext.environment.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex,
            subtleSelection: settings.subtleSelection,
            brightenInDarkMode: settings.brightenInDarkMode,
            unselectedFillOpacity: settings.unselectedFillOpacity,
            increaseContrast: renderContext.environment.displayAccessibility.increaseContrast,
            accent: settings.accentColor
        )
        let anchorActiveEdgeColor = sidebarGroupHeaderAnchorActiveEdgeNSColor(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            subtleSelection: settings.subtleSelection,
            sidebarSelectionColorHex: settings.selectionColorHex,
            colorScheme: renderContext.environment.colorScheme,
            increaseContrast: renderContext.environment.displayAccessibility.increaseContrast
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        let activity = Self.workspaceGroupActivity(
            runningCount: Self.workspaceGroupRunningCount(
                memberWorkspaceIds: memberWorkspaceIds,
                workspaceRowsById: workspaceRowsById
            ),
            memberWorkspaceIds: memberWorkspaceIds,
            unreadSnapshot: unreadSnapshot
        )
        let statusGlyph = SidebarCompactStatusGlyph.groupHeader(
            isCollapsed: group.isCollapsed,
            anchorId: liveAnchorId,
            memberIds: memberWorkspaceIds,
            members: memberStatusGlyphs,
            unread: {
                let summary = unreadSummariesByWorkspaceId[$0]
                return (summary?.unreadCount ?? 0, settings.showsNotificationMessage ? summary?.latestNotificationText : nil)
            }
        )
        let canMarkAnchorRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
        )
        let canMarkAnchorUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
        )
        let anchorHasLatestNotification = liveAnchorId.map {
            notificationIndex.hasNotification(workspaceId: $0)
        } ?? false
        let canMarkAllRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: memberWorkspaceIds
        )
        let canMarkAllUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: memberWorkspaceIds
        )
        let rowId = SidebarWorkspaceRenderItemID.group(group.id)
        let isPointerHovering = pointerInteractionMonitor.hoveredRowId == rowId
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: group.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: group.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        return SidebarWorkspaceGroupRowSnapshot(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            anchorActiveEdgeColor: anchorActiveEdgeColor,
            memberCount: memberWorkspaceIds.count,
            activity: activity,
            hasVisibleMembers: !group.isCollapsed && !memberWorkspaceIds.isEmpty,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            statusGlyph: statusGlyph,
            shortcutDigit: nil,
            shortcutModifierSymbol: nil,
            showsShortcutHint: false,
            isPointerHovering: isPointerHovering,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: cwdContextMenuItems,
            newWorkspacePlacement: newWorkspacePlacement,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.id,
            isBeingDragged: dragState.draggedTabId == dragIdentity,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets,
            notificationBadgeColorHex: settings.notificationBadgeColorHex
        )
    }

    /// Assembles one group row from immutable values when the lazy stack asks
    /// for it. Model references appear only inside user-invoked action
    /// closures; row realization performs no observable reads or mutations.
    func sidebarWorkspaceGroupRow(
        snapshot: SidebarWorkspaceGroupRowSnapshot
    ) -> SidebarWorkspaceGroupRowView {
        let rowId = SidebarWorkspaceRenderItemID.group(snapshot.groupId)
        let actions = makeWorkspaceGroupHeaderActions(
            groupId: snapshot.groupId,
            fallbackGroupName: snapshot.name,
            fallbackAnchorWorkspaceId: snapshot.anchorWorkspaceId,
            placement: snapshot.newWorkspacePlacement,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        let header = SidebarWorkspaceGroupHeaderView(
            groupId: snapshot.groupId,
            name: snapshot.name,
            tintHex: snapshot.tintHex,
            isCollapsed: snapshot.isCollapsed,
            isPinned: snapshot.isPinned,
            isAnchorActive: snapshot.isAnchorActive,
            isMultiSelected: snapshot.isMultiSelected,
            multiSelectionBackgroundStyle: snapshot.multiSelectionBackgroundStyle,
            anchorActiveEdgeColor: snapshot.anchorActiveEdgeColor,
            memberCount: snapshot.memberCount,
            activity: snapshot.activity,
            hasVisibleMembers: snapshot.hasVisibleMembers,
            canMarkRead: snapshot.canMarkRead,
            canMarkUnread: snapshot.canMarkUnread,
            hasLatestNotifications: snapshot.hasLatestNotifications,
            canMarkAllRead: snapshot.canMarkAllRead,
            canMarkAllUnread: snapshot.canMarkAllUnread,
            statusGlyph: snapshot.statusGlyph,
            shortcutDigit: snapshot.shortcutDigit,
            shortcutModifierSymbol: snapshot.shortcutModifierSymbol,
            showsShortcutHint: snapshot.showsShortcutHint,
            isPointerHovering: snapshot.isPointerHovering,
            shortcutHintXOffset: snapshot.shortcutHintXOffset,
            shortcutHintYOffset: snapshot.shortcutHintYOffset,
            fontScale: snapshot.fontScale,
            cwdContextMenuItems: snapshot.cwdContextMenuItems,
            newWorkspacePlacement: snapshot.newWorkspacePlacement,
            rowSpacing: snapshot.rowSpacing,
            isFirstRow: snapshot.isFirstRow,
            isBeingDragged: snapshot.isBeingDragged,
            topDropIndicatorVisible: snapshot.topDropIndicatorVisible,
            bottomDropIndicatorVisible: snapshot.bottomDropIndicatorVisible,
            notificationBadgeColorHex: snapshot.notificationBadgeColorHex,
            actions: actions,
            onContextMenuAppear: {},
            onContextMenuDisappear: {}
        )

        return SidebarWorkspaceGroupRowView(
            header: header,
            groupId: snapshot.groupId,
            shouldCollectWorkspaceDropTargets: snapshot.shouldCollectWorkspaceDropTargets,
            onPointerFrameChange: { [pointerInteractionMonitor, groupId = snapshot.groupId] frame in
                // Headers retain their group identity throughout a drag.
                pointerInteractionMonitor.updateFrame(frame, for: rowId, workspaceId: groupId)
            },
            onPointerFrameDisappear: { [pointerInteractionMonitor] in
                pointerInteractionMonitor.removeFrame(for: rowId)
            }
        )
    }

    /// Builds the one live action bundle shared by the SwiftUI and AppKit
    /// group-header renderers. The stable group id is captured; mutable anchor
    /// and member ids are resolved only when an action is invoked.
    @MainActor
    private func makeWorkspaceGroupHeaderActions(
        groupId: UUID,
        fallbackGroupName: String,
        fallbackAnchorWorkspaceId: UUID,
        placement: WorkspaceGroupNewPlacement?,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) -> SidebarGroupHeaderRowActions {
        let tabManager = self.tabManager
        let notificationStore = self.notificationStore
        let resolveLiveAnchor: () -> (TabManager, UUID)? = { [weak tabManager] in
            guard let tabManager,
                  let anchorId = tabManager.workspaceGroupAnchor(for: groupId)?.id else {
                return nil
            }
            return (tabManager, anchorId)
        }
        let resolvePlacement: () -> WorkspaceGroupNewPlacement = {
            placement
                ?? UserDefaultsSettingsClient(defaults: .standard)
                    .value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        }
        let resolveNotificationState: () -> SidebarGroupHeaderRowActions.NotificationState = {
            [resolveLiveAnchor, weak notificationStore] in
            guard let (tabManager, anchorId) = resolveLiveAnchor(),
                  let notificationStore else {
                return .unavailable
            }
            let memberIds = tabManager.tabs.compactMap { tab in
                tab.groupId == groupId ? tab.id : nil
            }
            return .init(
                canMarkRead: notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]),
                canMarkUnread: notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]),
                hasLatestNotifications: notificationStore.latestNotification(forTabId: anchorId) != nil,
                canMarkAllRead: memberIds.contains {
                    notificationStore.canMarkWorkspaceRead(forTabIds: [$0])
                },
                canMarkAllUnread: memberIds.contains {
                    notificationStore.canMarkWorkspaceUnread(forTabIds: [$0])
                }
            )
        }

        var actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: { [weak tabManager] modifiers in
                guard let tabManager else { return }
                Self.focusWorkspaceGroupAnchor(
                    groupId: groupId,
                    modifiers: modifiers,
                    tabManager: tabManager,
                    selectedTabIds: selectedTabIds,
                    lastSidebarSelectionIndex: lastSidebarSelectionIndex
                )
            },
            onTapPlus: { [weak tabManager] in
                guard let tabManager else { return }
                _ = tabManager.createWorkspaceInGroup(
                    groupId: groupId,
                    placement: resolvePlacement()
                )
            },
            onRunResolvedItem: { [weak tabManager] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            onRename: { [weak tabManager, resolveLiveAnchor] in
                // Group headers have no inline title editor; rename in the
                // palette editor, which already owns group renames.
                guard let tabManager else { return }
                let currentName = tabManager.workspaceGroups
                    .first(where: { $0.id == groupId })?.name ?? fallbackGroupName
                AppDelegate.shared?.requestCommandPaletteRename(
                    CommandPaletteRenameTarget(
                        kind: .workspaceGroup(groupId: groupId),
                        currentName: currentName
                    ),
                    preferredWindow: resolveLiveAnchor().flatMap {
                        AppDelegate.shared?.mainWindowContainingWorkspace($0.1)
                    },
                    source: "groupContextMenu.rename"
                )
            },
            onTogglePinned: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onMarkRead: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markRead(forTabId: anchorId)
            },
            onMarkUnread: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markUnread(forTabId: anchorId)
            },
            onClearLatestNotifications: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.latestNotification(forTabId: anchorId) != nil else {
                    return
                }
                notificationStore.clearLatestNotification(forTabId: anchorId)
            },
            onMarkAllRead: { [resolveLiveAnchor, weak notificationStore] in
                guard let (tabManager, anchorId) = resolveLiveAnchor(),
                      let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != anchorId ? tab.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [resolveLiveAnchor, weak notificationStore] in
                guard let (tabManager, anchorId) = resolveLiveAnchor(),
                      let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != anchorId ? tab.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                    notificationStore.markUnread(forTabId: id)
                }
            },
            onUngroup: { [weak tabManager] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager] in
                guard let tabManager,
                      let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                          groupId: groupId,
                          fallbackGroupName: fallbackGroupName,
                          fallbackAnchorWorkspaceId: fallbackAnchorWorkspaceId
                      ) else {
                    return
                }
                let isPinned = tabManager.workspaceGroups
                    .first(where: { $0.id == groupId })?.isPinned ?? false
                if isPinned || confirmation.containedWorkspaceCount > 0 {
                    guard confirmDeleteWorkspaceGroup(
                        groupName: confirmation.groupName,
                        memberCount: confirmation.containedWorkspaceCount
                    ) else {
                        return
                    }
                }
                tabManager.deleteWorkspaceGroup(confirmed: confirmation)
            },
            onEditConfig: {
                SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            }
        )
        actions.notificationState = resolveNotificationState
        return actions
    }

    /// Applies one shared group-header selection action to the live anchor.
    @MainActor
    static func focusWorkspaceGroupAnchor(
        groupId: UUID,
        modifiers: NSEvent.ModifierFlags,
        tabManager: TabManager,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) {
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }),
              let anchor = tabManager.workspaceGroupAnchor(for: groupId),
              let target = tabManager.workspaceGroupHeaderTarget(for: groupId) else { return }
        let hasRealMember = tabManager.tabs.contains { $0.groupId == groupId && $0.id != anchor.id }
        if group.anchorWorkspaceProvenance == .generated,
           !hasRealMember,
           tabManager.workspaceGroupGeneratedAnchorIsUntouched(anchor) {
            tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
            return
        }

        let anchorId: UUID
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            let selection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                current: selectedTabIds.wrappedValue,
                clickedAnchorId: anchor.id,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            selectedTabIds.wrappedValue = selection
            tabManager.selectWorkspace(target)
            anchorId = anchor.id
        } else {
            tabManager.selectWorkspace(target)
            anchorId = target.id
            if selectedTabIds.wrappedValue != [anchorId] {
                selectedTabIds.wrappedValue = [anchorId]
            }
        }
        lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == anchorId }
    }
}
