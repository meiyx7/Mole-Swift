import Foundation
import SwiftUI

/// Supported interface languages for the Mole GUI.
enum Language: String, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }

    /// Display name shown in the language picker (always in its own script so
    /// the user can recognise it regardless of the active language).
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// Observable language controller. On first launch, picks the system
/// preferred language (English for en-based locales, Chinese otherwise),
/// then persists the user's explicit choice to UserDefaults for subsequent
/// launches. Drives live re-rendering of every view that observes it.
///
/// Not `@MainActor`-isolated so that non-view helpers (e.g. `Feature.title`)
/// can call `t(_:_:)` synchronously. All mutations happen from `@MainActor`
/// SwiftUI views, so `@Published` remains main-thread-safe.
final class Localization: ObservableObject {
    @Published private(set) var language: Language

    static let storageKey = "appLanguage"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        if let lang = stored.flatMap({ Language(rawValue: $0) }) {
            // User has explicitly chosen a language before.
            self.language = lang
        } else {
            // First launch: follow the system preferred language.
            self.language = Self.detectSystemLanguage()
        }
    }

    /// Detects the system preferred language and maps it to a supported
    /// `Language`. Falls back to English for any locale we don't recognise
    /// as Chinese, so non-CJK users get English instead of Chinese.
    private static func detectSystemLanguage() -> Language {
        let preferred = Locale.preferredLanguages.first ?? "en"
        // Locale identifier like "zh-Hans-CN", "en-US", "ja-JP".
        if preferred.lowercased().hasPrefix("zh") {
            return .zh
        }
        return .en
    }

    /// Updates the active language and persists the choice.
    func setLanguage(_ language: Language) {
        guard language != self.language else { return }
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
    }

    /// Pick a string by current language: `loc.t("中文", "English")`.
    func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }
}
