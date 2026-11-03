import Testing
import AppKit
import CmuxSidebar
import CmuxNotifications
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral gate for the workspace sidebar's lazy-layout contract: layout
/// and diff work must stay O(visible rows) no matter how many workspaces are
/// open, and updates must converge (no self-sustaining invalidation).
///
/// The contract has regressed five times through five different mechanisms —
/// per-row anchorPreference aggregation (#5323), per-row String ids (#5764),
/// animated row-height interpolation (#5845), a force-measuring custom Layout
/// (#6210), and GeometryReader → @State row-height feedback (#6556) — and each
/// shipped to stable before being detected, because nothing exercised the
/// sidebar at the 100+ workspace scale where O(N) per pass becomes a
/// main-thread livelock (issue #2586). These tests mount the real
/// `VerticalTabsSidebar` at that scale and count actual row body evaluations
/// through `SidebarLazyContractProbe`, so ANY future mechanism that realizes
/// the whole list or loops the AttributeGraph fails here instead of on a
/// user's machine. `scripts/check-sidebar-lazy-layout.py` bans the known
/// source shapes; this is the mechanism-independent backstop.
@Suite(.serialized)
final class SidebarLazyLayoutScaleTests {
    static let workspaceCount = 300
    /// Scale for the contract tests whose assertions are work COUNTS — a
    /// per-row bound, a per-update ratio, or an O(N)-vs-O(N²) projection
    /// ceiling that scales with the mounted list. Those invariants do not
    /// depend on the absolute list length, and 120 is both far past the
    /// ~20-row viewport (so native rows must still virtualize) and past the
    /// 100-workspace scale every historical regression was reported at.
    /// `workspaceCount` stays 300 for the mount test, which is specifically
    /// the "all 300 realized in one pass" gate.
    static let contractWorkspaceCount = 120
    private static let groupedWorkspaceCount = 20
    /// Generous ceiling for "how many rows may be realized for one viewport".
    /// A 640pt window shows ~20 rows; native row caching and prefetch may
    /// retain more, but a virtualization defeat realizes all 300.
    private static let realizedRowCeiling = 150

    final class InjectableMouseLocationWindow: NSWindow {
        var injectedMouseLocation = NSPoint.zero

        override var mouseLocationOutsideOfEventStream: NSPoint {
            injectedMouseLocation
        }
    }

    // Plain class (not @MainActor) so the probe's nonisolated `() -> Void`
    // closures can mutate it; bodies only run on the main thread. Same shape
    // as MinimalModeBodyProbeCounts in WorkspaceContentViewVisibilityTests.
    final class RowBodyCounter {
        var workspaceRowBodies = 0
        var groupHeaderBodies = 0
        var workspaceSnapshotBuilds = 0
        var workspaceRowInputProjections = 0
        // Snapshot builds bracketed by workspaceRowBody/workspaceRowBodyEnd,
        // i.e. synchronous work inside a single TabItemView.body evaluation.
        // Builds outside the bracket (onAppear refresh, observation publishers)
        // are legitimate and not counted here.
        var insideWorkspaceRowBody = false
        var snapshotBuildsInCurrentRowBody = 0
        var maxSnapshotBuildsInOneRowBody = 0
        func reset() {
            workspaceRowBodies = 0
            groupHeaderBodies = 0
            workspaceSnapshotBuilds = 0
            workspaceRowInputProjections = 0
            insideWorkspaceRowBody = false
            snapshotBuildsInCurrentRowBody = 0
            maxSnapshotBuildsInOneRowBody = 0
        }
    }

    @MainActor
    struct Harness {
        let tabManager: TabManager
        let unread: SidebarUnreadModel
        let counter: RowBodyCounter
        let window: InjectableMouseLocationWindow
        let defaultsSuiteName: String

        func tearDown() {
            window.contentView = nil
            window.close()
            UserDefaults(suiteName: defaultsSuiteName)?
                .removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    @MainActor
    static func mountSidebar(workspaceCount: Int, includeGroups: Bool = true) async throws -> Harness {
        _ = NSApplication.shared

        // Hermetic defaults: VerticalTabsSidebar picks between the workspace
        // list and extension/built-in sidebars via
        // @AppStorage(CmuxExtensionSidebarSelection.defaultsKey). A persisted
        // non-default provider on the host would mount the wrong sidebar and
        // the probes would never fire. Same pattern as
        // WorkspaceContentViewVisibilityTests.
        let defaultsSuiteName = "SidebarLazyLayoutScaleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )
        let tabManager = TabManager()
        while tabManager.tabs.count < workspaceCount {
            // Per-iteration pool + periodic run-loop turns: the app creates
            // workspaces one per event-loop turn, with AppKit popping the
            // autorelease pool between turns. Creating hundreds inside one
            // main-actor job accumulates every autoreleased object from the
            // O(N) per-add snapshot work into a single pool, and the final
            // objc_autoreleasePoolPop then hangs or crashes the test host
            // (observed as Signal 11 in AutoreleasePoolPage::releaseUntil).
            autoreleasepool {
                _ = tabManager.addWorkspace(
                    select: false,
                    autoWelcomeIfNeeded: false,
                    autoRefreshMetadata: false
                )
            }
            if tabManager.tabs.count % 20 == 0 {
                Self.turnMainRunLoopOnce(layingOut: nil)
                await Task.yield()
            }
        }

        // Group the first workspaces (top of the list, inside the viewport) so
        // group-header rows — assembled by sidebarWorkspaceGroupRow(...) in
        // VerticalTabsSidebar+WorkspaceGroups.swift, a historical regression
        // site (#4385) — are exercised by the same realization bounds.
        let groupCandidates = includeGroups ? Array(tabManager.tabs.prefix(Self.groupedWorkspaceCount).map(\.id)) : []
        for chunkStart in stride(from: 0, to: groupCandidates.count, by: 4) {
            let children = Array(groupCandidates[chunkStart..<min(chunkStart + 4, groupCandidates.count)])
            _ = tabManager.createWorkspaceGroup(
                name: "Group \(chunkStart / 4)",
                childWorkspaceIds: children,
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        }
        Self.turnMainRunLoopOnce(layingOut: nil)

        let unread = SidebarUnreadModel()
        let counter = RowBodyCounter()

        let root = VerticalTabsSidebar(
            fileExplorerState: FileExplorerState(),
            sessionIndexStore: SessionIndexStore(),
            sidebarUnread: unread,
            titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
            windowId: UUID(),
            onToggleSidebar: {},
            onNewTab: {},
            observedWindowReference: WeakWindowReference(),
            chromeBackgroundColor: .black,
            selection: .constant(.tabs),
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil),
            sidebarRenderWorkerClient: .constant(nil)
        )
        .frame(width: 280)
        .environmentObject(tabManager)
        .environmentObject(CmuxConfigStore())
        .environmentObject(TerminalNotificationStore.shared)
        .environmentObject(SidebarState())
        .environmentObject(SidebarSelectionState())
        .environment(
            \.sidebarLazyContractProbe,
            SidebarLazyContractProbe(
                workspaceRowBody: {
                    counter.workspaceRowBodies += 1
                    counter.insideWorkspaceRowBody = true
                    counter.snapshotBuildsInCurrentRowBody = 0
                },
                workspaceRowBodyEnd: {
                    counter.insideWorkspaceRowBody = false
                },
                groupHeaderRowBody: { counter.groupHeaderBodies += 1 },
                workspaceSnapshotBuild: {
                    counter.workspaceSnapshotBuilds += 1
                    guard counter.insideWorkspaceRowBody else { return }
                    counter.snapshotBuildsInCurrentRowBody += 1
                    counter.maxSnapshotBuildsInOneRowBody = max(
                        counter.maxSnapshotBuildsInOneRowBody,
                        counter.snapshotBuildsInCurrentRowBody
                    )
                },
                workspaceRowInputProjection: {
                    counter.workspaceRowInputProjections += 1
                }
            )
        )
        .defaultAppStorage(defaults)

        let window = InjectableMouseLocationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window; without this, close() performs AppKit's own
        // release on top of ARC's and the double-release SEGVs the test host
        // at the next autorelease-pool pop (zombies: "-[NSKVONotifying_NSWindow
        // release]: message sent to deallocated instance"). That crash killed
        // the host before the pass was recorded, and CI masked it (#5641).
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        return Harness(
            tabManager: tabManager,
            unread: unread,
            counter: counter,
            window: window,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    /// One synchronous run-loop turn. Kept out of the async context so the
    /// `RunLoop.run(_:before:)` call is legal under Swift 6, and wrapped in its
    /// own autorelease pool so drained main-queue work cannot pile objects
    /// into the enclosing job's pool.
    @MainActor
    static func turnMainRunLoopOnce(layingOut window: NSWindow?) {
        autoreleasepool {
            window?.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    static func drainMainRunLoop(for window: NSWindow, iterations: Int = 25) async {
        for _ in 0..<iterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }

    /// Pumps the main run loop until snapshot and parent-projection work stays
    /// flat for `quietWindow`, or `maxIterations` turns have run.
    ///
    /// The window is measured in time, not turns, because the sidebar's own
    /// invalidation stages are timed: row-affecting workspace fields coalesce
    /// for `Workspace.sidebarImmediateObservationCoalesceInterval` (50ms) and
    /// status/metadata fields debounce for 40ms before a row is invalidated.
    /// The quiet window spans twice the longest stage so no coalesced or
    /// debounced invalidation is still pending. A few idle turns could otherwise
    /// declare quiet inside that gap.
    @MainActor
    static func drainUntilRowWorkQuiesces(
        for window: NSWindow,
        counter: RowBodyCounter,
        quietWindow: Duration = Duration.nanoseconds(
            Workspace.sidebarImmediateObservationCoalesceInterval.magnitude
        ) * 2,
        maxIterations: Int = 200
    ) async {
        let clock = ContinuousClock()
        var quietSince = clock.now
        var previousWork = -1
        for _ in 0..<maxIterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
            let work = counter.workspaceSnapshotBuilds + counter.workspaceRowInputProjections
            if work != previousWork {
                previousWork = work
                quietSince = clock.now
            } else if clock.now - quietSince >= quietWindow {
                return
            }
        }
    }


    /// Mounting the sidebar with 300 workspaces must realize only the rows a
    /// single viewport needs. Realizing all of them is the #5323/#6210 defeat:
    /// at scale, every subsequent update pays an O(N) layout pass and the main
    /// thread livelocks.
    @Test
    @MainActor
    func testMountRealizesOnlyViewportRowsAt300Workspaces() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        // Let the snapshot owner converge before inspecting native row reuse.
        await Self.drainUntilRowWorkQuiesces(for: harness.window, counter: harness.counter)

        let table = try #require(Self.nativeSidebarTable(in: harness.window.contentView))
        #expect(table.numberOfRows >= Self.workspaceCount)
        let realizedViews = (0..<table.numberOfRows).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false)
        }
        let workspaceRows = realizedViews.compactMap { $0 as? SidebarWorkspaceRowTableCellView }
        #expect(!workspaceRows.isEmpty, "Sidebar mounted but no native workspace row was realized.")
        #expect(
            realizedViews.count < Self.realizedRowCeiling,
            "The native table must not realize all \(Self.workspaceCount) workspace rows for one viewport."
        )
        #expect(
            realizedViews.contains { $0 is SidebarGroupHeaderTableCellView },
            "Groups were created at the top of the list but no native group header was realized."
        )
    }

    @MainActor
    private static func nativeSidebarTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let container = view as? SidebarWorkspaceTableContainerView {
            return container.tableView
        }
        return view.subviews.lazy.compactMap { nativeSidebarTable(in: $0) }.first
    }

    /// A simultaneous workspace-publisher burst must cross the parent snapshot
    /// boundary once per batch. Re-projecting all 300 row inputs once per
    /// emitting workspace is O(N²) main-actor work even though the native table
    /// realizes only viewport rows.
    @Test
    @MainActor
    func testWorkspacePublisherBatchProjectsParentListLinearly() async throws {
        // The assertion is a ratio (parent projections per emitting
        // workspace), so the O(N) / O(N²) separation is the same at any
        // mounted length: one invalidation per emitter would cost
        // batch × list projections against a ceiling of 4 × list.
        let workspaceCount = Self.contractWorkspaceCount
        let harness = try await Self.mountSidebar(workspaceCount: workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        // Wait for initial workspace publishers to quiesce before isolating
        // the operation count for this burst. The exact number of accepted
        // initial projections is an implementation detail; the invariant is
        // that every workspace is projected and the owner reaches a stable
        // snapshot before the counter resets.
        let initialDeadline = ProcessInfo.processInfo.systemUptime + 3
        var previousInitialBuildCount = -1
        var stableInitialPasses = 0
        while stableInitialPasses < 4,
              ProcessInfo.processInfo.systemUptime < initialDeadline {
            Self.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
            let currentBuildCount = harness.counter.workspaceSnapshotBuilds
            if currentBuildCount == previousInitialBuildCount {
                stableInitialPasses += 1
            } else {
                previousInitialBuildCount = currentBuildCount
                stableInitialPasses = 0
            }
        }
        #expect(
            harness.counter.workspaceSnapshotBuilds >= workspaceCount,
            "Initial workspace values did not reach the snapshot owner."
        )
        #expect(
            stableInitialPasses == 4,
            "Initial workspace publishers did not quiesce before the batch measurement."
        )
        // Group creation publishes a separate row-input pass that may trail
        // the workspace snapshot publisher by one main-actor turn. Drain it
        // before resetting the counter so setup churn cannot contaminate the
        // measured burst.
        await Self.drainMainRunLoop(for: harness.window, iterations: 4)

        harness.counter.reset()
        let targets = Array(harness.tabManager.tabs.suffix(40))
        for (index, workspace) in targets.enumerated() {
            workspace.statusEntries["issue-6707.batch"] = SidebarStatusEntry(
                key: "issue-6707.batch",
                value: "batch update \(index)",
                icon: "bolt.fill"
            )
        }

        let refreshDeadline = ProcessInfo.processInfo.systemUptime + 3
        while harness.counter.workspaceSnapshotBuilds < targets.count,
              ProcessInfo.processInfo.systemUptime < refreshDeadline {
            Self.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }
        #expect(
            harness.counter.workspaceSnapshotBuilds >= targets.count,
            "The \(targets.count)-workspace publisher batch did not reach the snapshot owner."
        )
        await Self.drainMainRunLoop(for: harness.window)

        let projections = harness.counter.workspaceRowInputProjections
        #expect(projections > 0, "The parent row-input projection probe did not run.")
        #expect(
            projections <= harness.tabManager.tabs.count * 4,
            """
            \(projections) parent row-input projections ran for one \(targets.count)-workspace \
            event batch at \(harness.tabManager.tabs.count) workspaces. The batch must cause O(N) parent \
            projection work, not O(N²) work from one parent invalidation per emitter.
            """
        )
    }

}
