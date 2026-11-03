import Foundation
import Testing
@testable import CmuxSettings

@Suite("Personal UI language fallback")
struct LanguageSettingsOverrideTests {
    @Test(arguments: [(AppLanguage.en, "en"), (.ja, "en"), (.de, "en"), (.ar, "en"), (.zhHans, "zh-Hans"), (.zhHant, "zh-Hant")])
    func languageOptionsUseEnglishExceptChinese(language: AppLanguage, expected: String) {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        LanguageSettingsStore(defaults: defaults).applyLanguageOverride(language)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == [expected])
    }

    @Test(arguments: [([String](), "en"), (["en-US"], "en"), (["zh-CN"], "zh-Hans"), (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["ja-JP", "zh-Hans"], "en")])
    func systemSelectionUsesThePrimarySystemLanguage(languages: [String], expected: String) {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("system", forKey: "appLanguage")
        defaults.set(["fr"], forKey: "AppleLanguages")
        LanguageSettingsStore(defaults: defaults, systemLanguages: languages).reconcileLanguageOverrideAtLaunch()
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == [expected])
    }
}
