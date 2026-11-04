import Foundation

/// Settings under the dotted-id prefix `sidebar.*` — workspace-row
/// metadata visibility and layout.
public struct SidebarCatalogSection: SettingCatalogSection {
    /// Valid notification-preview line limits for settings UI and configuration parsing.
    public static let notificationMessageLineLimitRange = 1...50

    /// Resolves the shipped legacy layout contract together with the newer
    /// branch/directory placement preference.
    public static func stacksBranchAndDirectory(
        vertical: Bool,
        explicit: Bool
    ) -> Bool {
        vertical || explicit
    }

    public let hideAllDetails = DefaultsKey<Bool>(
        id: "sidebar.hideAllDetails",
        defaultValue: false,
        userDefaultsKey: "sidebarHideAllDetails"
    )

    /// Ordered information sections below the fixed workspace title and agent status.
    public let detailOrder = DefaultsKey<[String]>(
        id: "sidebar.detailOrder",
        defaultValue: SidebarWorkspaceDetail.allCases.map(\.rawValue),
        userDefaultsKey: "sidebarDetailOrder"
    )

    /// Show the agent status directly beneath the workspace title.
    public let showAgentStatusInSidebar = DefaultsKey<Bool>(
        id: "sidebar.showAgentStatusInSidebar",
        defaultValue: true,
        userDefaultsKey: "sidebarShowAgentStatusInSidebar"
    )

    /// Workspace title font size before sidebar and global scaling.
    public let titleFontSize = DefaultsKey<Double>(
        id: "sidebar.titleFontSize",
        defaultValue: 14,
        userDefaultsKey: "sidebarTitleFontSize"
    )

    /// Agent status badge font size before sidebar and global scaling.
    public let agentStatusFontSize = DefaultsKey<Double>(
        id: "sidebar.agentStatusFontSize",
        defaultValue: 12,
        userDefaultsKey: "sidebarAgentStatusFontSize"
    )

    /// Description and notification font size before sidebar and global scaling.
    public let descriptionFontSize = DefaultsKey<Double>(
        id: "sidebar.descriptionFontSize",
        defaultValue: 11,
        userDefaultsKey: "sidebarDescriptionFontSize"
    )

    /// Git branch font size before sidebar and global scaling.
    public let branchFontSize = DefaultsKey<Double>(
        id: "sidebar.branchFontSize",
        defaultValue: 10.5,
        userDefaultsKey: "sidebarBranchFontSize"
    )

    /// Working directory font size before sidebar and global scaling.
    public let directoryFontSize = DefaultsKey<Double>(
        id: "sidebar.directoryFontSize",
        defaultValue: 10,
        userDefaultsKey: "sidebarDirectoryFontSize"
    )

    /// Pull request, port and log font size before sidebar and global scaling.
    public let auxiliaryFontSize = DefaultsKey<Double>(
        id: "sidebar.auxiliaryFontSize",
        defaultValue: 9.5,
        userDefaultsKey: "sidebarAuxiliaryFontSize"
    )

    /// Maximum lines for each workspace information field; excess text uses a trailing ellipsis.
    public let informationLineLimit = DefaultsKey<Int>(
        id: "sidebar.informationLineLimit",
        defaultValue: 2,
        userDefaultsKey: "sidebarInformationLineLimit"
    )

    /// Show completed agent status in workspace rows and terminal tabs until the workspace is opened or marked as read.
    public let showInactiveAgentStatus = DefaultsKey<Bool>(
        id: "sidebar.showInactiveAgentStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarShowInactiveAgentStatus"
    )

    /// Animate working agent badges unless macOS Reduce Motion is enabled.
    public let animateAgentStatus = DefaultsKey<Bool>(
        id: "sidebar.animateAgentStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarAnimateAgentStatus"
    )

    /// Show agent status badges in terminal tabs.
    public let showAgentStatusInTabs = DefaultsKey<Bool>(
        id: "sidebar.showAgentStatusInTabs",
        defaultValue: true,
        userDefaultsKey: "sidebarShowAgentStatusInTabs"
    )

    /// Show the Codexpress panel and poll its local management API while visible.
    public let codexpressEnabled = DefaultsKey<Bool>(
        id: "sidebar.codexpressEnabled",
        defaultValue: true,
        userDefaultsKey: "sidebarCodexpressEnabled"
    )

    /// Uses the explicit port and private API key instead of Codexpress auto-discovery.
    public let codexpressManualConnection = DefaultsKey<Bool>(
        id: "sidebar.codexpressManualConnection",
        defaultValue: false,
        userDefaultsKey: "sidebarCodexpressManualConnection"
    )

    /// Local management API port used when manual connection is enabled.
    public let codexpressManagementPort = DefaultsKey<Int>(
        id: "sidebar.codexpressManagementPort",
        defaultValue: 17867,
        userDefaultsKey: "sidebarCodexpressManagementPort"
    )

    /// Management credential stored separately from cmux.json with owner-only permissions.
    public let codexpressManagementAPIKey = SecretFileKey(
        id: "sidebar.codexpressManagementAPIKey",
        fileName: "codexpress-management-api-key"
    )

    /// Seconds between local Codexpress status reads; never refreshes upstream balances automatically.
    public let codexpressPollIntervalSeconds = DefaultsKey<Double>(
        id: "sidebar.codexpressPollIntervalSeconds",
        defaultValue: 2,
        userDefaultsKey: "sidebarCodexpressPollIntervalSeconds"
    )

    /// Show each Codexpress source active request count.
    public let codexpressShowRequestCounts = DefaultsKey<Bool>(
        id: "sidebar.codexpressShowRequestCounts",
        defaultValue: true,
        userDefaultsKey: "sidebarCodexpressShowRequestCounts"
    )

    /// Show official account quota reset times.
    public let codexpressShowResetTimes = DefaultsKey<Bool>(
        id: "sidebar.codexpressShowResetTimes",
        defaultValue: true,
        userDefaultsKey: "sidebarCodexpressShowResetTimes"
    )

    /// Show Codexpress takeover, refresh and reset-card controls.
    public let codexpressShowActions = DefaultsKey<Bool>(
        id: "sidebar.codexpressShowActions",
        defaultValue: true,
        userDefaultsKey: "sidebarCodexpressShowActions"
    )

    /// Base font size for the Codexpress panel before global scaling.
    public let codexpressFontSize = DefaultsKey<Double>(
        id: "sidebar.codexpressFontSize",
        defaultValue: 11,
        userDefaultsKey: "sidebarCodexpressFontSize"
    )

    public let wrapWorkspaceTitles = DefaultsKey<Bool>(
        id: "sidebar.wrapWorkspaceTitles",
        defaultValue: true,
        userDefaultsKey: "sidebarWrapWorkspaceTitles"
    )

    public let showWorkspaceDescription = DefaultsKey<Bool>(
        id: "sidebar.showWorkspaceDescription",
        defaultValue: true,
        userDefaultsKey: "sidebarShowWorkspaceDescription"
    )

    public let workspaceDescriptionColorHex = DefaultsKey<String>(
        id: "sidebar.workspaceDescriptionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarWorkspaceDescriptionColorHex"
    )

    /// Bool-backed to match the legacy in-app store. The on-disk key
    /// `sidebarBranchVerticalLayout` is written as a Bool by every
    /// shipped cmux build; using an enum here would silently revert
    /// every user with a saved preference. `true` preserves the legacy
    /// vertical presentation: each panel's branch/directory record gets its
    /// own row, with branch and directory on separate subrows. When this is
    /// `false`, `stackBranchDirectory` can still opt the compact branch layout
    /// into separate branch and directory subrows.
    public let branchVerticalLayout = DefaultsKey<Bool>(
        id: "sidebar.branchVerticalLayout",
        defaultValue: true,
        userDefaultsKey: "sidebarBranchVerticalLayout"
    )

    public let stackBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.stackBranchDirectory",
        defaultValue: false,
        userDefaultsKey: "sidebarBranchDirectoryStacked"
    )

    public let pathLastSegmentOnly = DefaultsKey<Bool>(
        id: "sidebar.pathLastSegmentOnly",
        defaultValue: false,
        userDefaultsKey: "sidebarPathLastSegmentOnly"
    )

    public let showNotificationMessage = DefaultsKey<Bool>(
        id: "sidebar.showNotificationMessage",
        defaultValue: true,
        userDefaultsKey: "sidebarShowNotificationMessage"
    )

    /// Maximum notification-preview lines shown per workspace, defaulting to 12.
    public let notificationMessageLineLimit = DefaultsKey<Int>(
        id: "sidebar.notificationMessageLineLimit",
        defaultValue: 12,
        userDefaultsKey: "sidebarNotificationMessageLineLimit"
    )

    public let showBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.showBranchDirectory",
        defaultValue: true,
        userDefaultsKey: "sidebarShowBranchDirectory"
    )

    public let showPullRequests = DefaultsKey<Bool>(
        id: "sidebar.showPullRequests",
        defaultValue: true,
        userDefaultsKey: "sidebarShowPullRequest"
    )

    public let watchGitStatus = DefaultsKey<Bool>(
        id: "sidebar.watchGitStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarWatchGitStatus"
    )

    public let makePullRequestsClickable = DefaultsKey<Bool>(
        id: "sidebar.makePullRequestsClickable",
        defaultValue: true,
        userDefaultsKey: "sidebarMakePullRequestClickable"
    )

    public let openPullRequestLinksInCmuxBrowser = DefaultsKey<Bool>(
        id: "sidebar.openPullRequestLinksInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    )

    public let openPortLinksInCmuxBrowser = DefaultsKey<Bool>(
        id: "sidebar.openPortLinksInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenSidebarPortLinksInCmuxBrowser"
    )

    public let showSSH = DefaultsKey<Bool>(
        id: "sidebar.showSSH",
        defaultValue: true,
        userDefaultsKey: "sidebarShowSSH"
    )

    public let showPorts = DefaultsKey<Bool>(
        id: "sidebar.showPorts",
        defaultValue: true,
        userDefaultsKey: "sidebarShowPorts"
    )

    public let showLog = DefaultsKey<Bool>(
        id: "sidebar.showLog",
        defaultValue: true,
        userDefaultsKey: "sidebarShowLog"
    )

    public let showProgress = DefaultsKey<Bool>(
        id: "sidebar.showProgress",
        defaultValue: true,
        userDefaultsKey: "sidebarShowProgress"
    )

    /// Whether sidebar workspace rows append coding-agent usage (model,
    /// context-window percentage, estimated API cost) to the agent status
    /// entry (`sidebar.showAgentUsage`). Defaults to off: sampling reads the
    /// agent transcript off the main actor after hook events.
    public let showAgentUsage = DefaultsKey<Bool>(
        id: "sidebar.showAgentUsage",
        defaultValue: false,
        userDefaultsKey: "sidebarShowAgentUsage"
    )

    /// Whether sidebar workspace rows show the loading spinner for running
    /// coding agents and manual `cmux workspace loading` loaders
    /// (`sidebar.showAgentActivity`). Defaults to on.
    public let showAgentActivity = DefaultsKey<Bool>(
        id: "sidebar.showAgentActivity",
        defaultValue: true,
        userDefaultsKey: "sidebarShowAgentActivity"
    )

    /// Which side of the workspace row the loading spinner appears on
    /// (`sidebar.loadingSpinnerPosition`). Defaults to leading (left), sharing
    /// the unread-badge slot.
    public let loadingSpinnerPosition = DefaultsKey<SidebarIndicatorPosition>(
        id: "sidebar.loadingSpinnerPosition",
        defaultValue: .leading,
        userDefaultsKey: "sidebarLoadingSpinnerPosition"
    )

    /// Which side of the workspace row the unread notification badge appears on
    /// (`sidebar.notificationBadgePosition`). Defaults to leading (left).
    public let notificationBadgePosition = DefaultsKey<SidebarIndicatorPosition>(
        id: "sidebar.notificationBadgePosition",
        defaultValue: .leading,
        userDefaultsKey: "sidebarNotificationBadgePosition"
    )

    /// Whether coding-agent status entries reported by agent hooks (for
    /// example Claude Code's "Running") render as a tinted glyph on the
    /// workspace title line instead of their own metadata row
    /// (`sidebar.compactAgentStatus`). Defaults to off; other status entries
    /// keep their rows either way.
    public let compactAgentStatus = DefaultsKey<Bool>(
        id: "sidebar.compactAgentStatus",
        defaultValue: false,
        userDefaultsKey: "sidebarCompactAgentStatus"
    )

    /// `sidebar.compactAgentStatus` glyph overrides: SF Symbol names keyed by
    /// state (`needsInput`, `terminal`, `pullRequestMerged`, ...).
    public let compactStatusIcons = DefaultsKey<[String: String]>(
        id: "sidebar.compactStatusIcons",
        defaultValue: [:],
        userDefaultsKey: "sidebarCompactStatusIcons"
    )

    public let showCustomMetadata = DefaultsKey<Bool>(
        id: "sidebar.showCustomMetadata",
        defaultValue: true,
        userDefaultsKey: "sidebarShowStatusPills"
    )

    public let rightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth",
        defaultValue: RightSidebarWidthSettings.noOverrideValue,
        userDefaultsKey: RightSidebarWidthSettings.maxWidthKey
    )

    public let rememberedRightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth.remembered",
        defaultValue: RightSidebarWidthSettings.defaultConfiguredMaximumWidth,
        userDefaultsKey: RightSidebarWidthSettings.rememberedMaxWidthKey
    )

    public let activeTabIndicatorStyle = DefaultsKey<String>(
        id: "sidebar.activeTabIndicatorStyle",
        defaultValue: "leftRail",
        userDefaultsKey: "sidebarActiveTabIndicatorStyle"
    )

    public let selectionColorHex = DefaultsKey<String>(
        id: "sidebar.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "sidebar.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    public init() {}
}
