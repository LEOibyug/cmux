import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarIdentifierFormattingTests {
    @Test(arguments: [(1, ":1"), (2014, ":2014"), (17867, ":17867"), (65535, ":65535")])
    func portIdentifiersAreLocaleIndependent(port: Int, expected: String) {
        #expect(SidebarPortDisplayText.label(for: port) == expected)
    }

    @Test
    func portTooltipKeepsTheUnformattedPortNumber() {
        let tooltip = SidebarPortDisplayText.openTooltip(for: 2014)
        #expect(tooltip.contains("2014"))
        #expect(!tooltip.contains("%lld"))
        #expect(!tooltip.contains("2,014"))
    }
}
