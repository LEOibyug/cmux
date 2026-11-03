import Foundation

/// Saved language-menu choices. The personal build renders Chinese choices in
/// Chinese and all other explicit choices in English.
public enum AppLanguage: String, CaseIterable, Sendable, SettingCodable {
    case system, en, ar, bs, zhHans = "zh-Hans", zhHant = "zh-Hant", da, de, es, fr, it, ja, ko, nb, pl, ptBR = "pt-BR", ru, th, tr, vi
}
