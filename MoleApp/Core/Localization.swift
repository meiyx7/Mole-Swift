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

/// Observable language controller. Defaults to Chinese (`zh`) on first launch,
/// persists the choice to UserDefaults, and drives live re-rendering of every
/// view that observes it.
///
/// Not `@MainActor`-isolated so that non-view helpers (e.g. `Feature.title`)
/// can call `t(_:_:)` synchronously. All mutations happen from `@MainActor`
/// SwiftUI views, so `@Published` remains main-thread-safe.
final class Localization: ObservableObject {
    @Published private(set) var language: Language

    static let storageKey = "appLanguage"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        // Default to Chinese when nothing (or an unknown value) is stored.
        self.language = Language(rawValue: stored ?? "") ?? .zh
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
