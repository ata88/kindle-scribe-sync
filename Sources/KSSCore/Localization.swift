import Foundation

/// App-wide localization with German as the source language.
///
/// Every user-facing string is written in German and wrapped in `L(...)`;
/// `Translations.en` holds the English text. A unit test scans all sources
/// and fails if a `L("…")` literal has no English translation, so the two
/// languages can never drift apart.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, de, en
    public var id: String { rawValue }
}

public enum Loc {
    /// UserDefaults key the app stores the user's choice under.
    public static let defaultsKey = "appLanguage"

    /// "de" or "en" – resolved from the user's choice or the system language.
    public static var current: String {
        let choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
        switch choice {
        case .de: return "de"
        case .en: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "de"
            return preferred.hasPrefix("de") ? "de" : (preferred.hasPrefix("en") ? "en" : "de")
        }
    }

    public static var locale: Locale { Locale(identifier: current == "en" ? "en_US" : "de_DE") }
}

/// Translate a German source string.
public func L(_ german: String) -> String {
    guard Loc.current == "en" else { return german }
    return Translations.en[german] ?? german
}

/// Translate and format (`%@`, `%d`, `%ld` …).
public func L(_ german: String, _ args: CVarArg...) -> String {
    String(format: L(german), locale: Loc.locale, arguments: args)
}
