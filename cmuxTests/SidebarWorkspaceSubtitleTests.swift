import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Workspace subtitles omit a value that only repeats the workspace title.
@MainActor @Suite struct SidebarWorkspaceSubtitleTests {
    @Test func aSubtitleThatOnlyRepeatsTheTitleIsDropped() {
        let echo: [String] = SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~"], title: "~")
        #expect(echo.isEmpty)
        #expect(SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~"], title: "Build") == ["~"])
        #expect(SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~/src", "src"], title: "src") == ["~/src", "src"])
        let none: [String] = SidebarWorkspaceSnapshotFactory.droppingTitleEcho([], title: "~")
        #expect(none.isEmpty)
    }

}
