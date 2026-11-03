import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionID")
struct SettingsSectionIDTests {
    @Test func everyCaseHasNonEmptyTitleAndSymbol() {
        for section in SettingsSectionID.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsSectionID.allCases.map(\.title)
        #expect(titles.count == Set(titles).count)
    }

    @Test(arguments: SettingsSectionID.allCases)
    func missingAnchorLandsOnTheRequestedSectionHeader(section: SettingsSectionID) {
        let destination = section.navigationDestination(providedAnchor: nil)
        #expect(destination.section == section)
        #expect(destination.anchorID == "section:\(section.rawValue)")
    }

    @Test(arguments: [
        (SettingsSectionID.app, "setting:app:language"),
        (.terminal, "setting:terminal:copy-on-select"),
        (.terminal, "section:terminal")
    ])
    func rowAnchorsArePreserved(section: SettingsSectionID, anchor: String) {
        let destination = section.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == section)
        #expect(destination.anchorID == anchor)
    }

    @Test func notificationUserInfoResolvesTargetAndAnchor() throws {
        let destination = try #require(SettingsSectionID.navigationDestination(userInfo: ["target": "app", "anchor": "setting:app:language"]))
        #expect(destination.section == .app)
        #expect(destination.anchorID == "setting:app:language")
        #expect(SettingsSectionID.navigationDestination(userInfo: ["target": "notASection"]) == nil)
        #expect(SettingsSectionID.navigationDestination(userInfo: nil) == nil)
    }
}
