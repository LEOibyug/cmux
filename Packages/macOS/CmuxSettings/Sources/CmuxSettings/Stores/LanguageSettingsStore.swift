import Foundation

/// Persists the selected language and resolves this personal build to English or Chinese.
///
/// Other language choices retain their settings value but render in English.
/// System follows the first system language only when it is Chinese.
public struct LanguageSettingsStore: Sendable {
    // UserDefaults is thread-safe; the immutable reference is constructor-injected.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let systemLanguages: [String]
    private let keys = AppCatalogSection()

    /// Creates a store with an isolated defaults source and system-language snapshot.
    ///
    /// - Parameters:
    ///   - defaults: The app's defaults or an isolated test suite.
    ///   - systemLanguages: OS preferences, independent of cmux's per-app override.
    public init(defaults: UserDefaults, systemLanguages: [String] = []) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages
    }

    /// The saved menu choice; unrecognized values resolve to System.
    public var storedLanguage: AppLanguage { keys.language.value(in: defaults) }

    /// Applies English, Simplified Chinese or Traditional Chinese for the selection.
    ///
    /// - Parameter language: The selected menu option; non-Chinese options use English.
    public func applyLanguageOverride(_ language: AppLanguage) {
        defaults.set([localization(for: language)], forKey: "AppleLanguages")
    }

    /// Resolves the saved selection before Foundation loads localized UI resources.
    public func reconcileLanguageOverrideAtLaunch() {
        applyLanguageOverride(storedLanguage)
    }

    private func localization(for language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .system:
            guard let identifier = systemLanguages.first else { return "en" }
            let locale = Locale(identifier: identifier)
            guard locale.language.languageCode?.identifier == "zh" else { return "en" }
            return locale.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        default: return "en"
        }
    }
}
