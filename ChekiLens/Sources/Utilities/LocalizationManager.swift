import SwiftUI
import Foundation

// MARK: - AppLanguageMode (Task 6.2: 繁體中文 / 日本語 語系管理與系統自動匹配)

/// App 語系設定模式：
/// - `system`：依照 iOS 系統首選語言自動匹配（若系統首選為日文則顯示日文，否則顯示繁體中文）
/// - `traditionalChinese`：固定顯示繁體中文 (`zh-Hant`)
/// - `japanese`：固定顯示日本語 (`ja`)
enum AppLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return L10n.isJapanese ? "システム設定に従う" : "跟隨系統"
        case .traditionalChinese:
            return "繁體中文"
        case .japanese:
            return "日本語"
        }
    }

    /// 根據設定與 iOS 系統首選語言解析目前是否為日文語系
    var isResolvedJapanese: Bool {
        switch self {
        case .japanese:
            return true
        case .traditionalChinese:
            return false
        case .system:
            for lang in Locale.preferredLanguages {
                let lower = lang.lowercased()
                if lower.hasPrefix("ja") {
                    return true
                }
                if lower.hasPrefix("zh") {
                    return false
                }
            }
            return Locale.current.language.languageCode?.identifier.lowercased() == "ja"
        }
    }

    /// 供 SwiftUI `.environment(\.locale, ...)` 使用之 `Locale`
    var resolvedLocale: Locale {
        isResolvedJapanese ? Locale(identifier: "ja") : Locale(identifier: "zh-Hant")
    }

    /// 供 `DateFormatter` 與月曆元件使用之區域 `Locale`
    var resolvedFormattingLocale: Locale {
        isResolvedJapanese ? Locale(identifier: "ja_JP") : Locale(identifier: "zh_Hant_TW")
    }
}

// MARK: - L10n 雙語即時查詢工具

enum L10n {
    static let storageKey = "appLanguageMode"

    static var currentMode: AppLanguageMode {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguageMode.system.rawValue
        return AppLanguageMode(rawValue: raw) ?? .system
    }

    static var isJapanese: Bool {
        currentMode.isResolvedJapanese
    }

    static var currentLocale: Locale {
        currentMode.resolvedLocale
    }

    static var formattingLocale: Locale {
        currentMode.resolvedFormattingLocale
    }

    /// 依目前生效語系回傳繁體中文或日文字串
    static func tr(_ zhHant: String, _ ja: String) -> String {
        isJapanese ? ja : zhHant
    }
}

// MARK: - 全域外觀模式、語系與動態字級 (Dynamic Type) ViewModifier

struct AppAppearanceAndLocaleModifier: ViewModifier {
    @AppStorage("appAppearanceMode") private var appAppearanceModeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("appLanguageMode") private var appLanguageModeRaw: String = AppLanguageMode.system.rawValue

    private var preferredScheme: ColorScheme? {
        (AppAppearanceMode(rawValue: appAppearanceModeRaw) ?? .system).resolvedColorScheme
    }

    private var resolvedLocale: Locale {
        (AppLanguageMode(rawValue: appLanguageModeRaw) ?? .system).resolvedLocale
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredScheme)
            .environment(\.locale, resolvedLocale)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

extension View {
    /// 套用使用者選定的深淺色外觀模式、繁中/日文語系環境與 Dynamic Type 動態字級上限保護
    func applyAppAppearanceAndLocale() -> some View {
        modifier(AppAppearanceAndLocaleModifier())
    }
}
