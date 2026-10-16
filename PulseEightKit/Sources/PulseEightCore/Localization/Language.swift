import Foundation

/// A language the apps can be shown in.
public struct Language: Hashable, Sendable, Codable {
    /// Short code, e.g. "en" or "de".
    public var code: String
    /// The language's own name for itself, shown in the language picker ("English", "Deutsch").
    public var nativeName: String

    public init(code: String, nativeName: String) {
        self.code = code
        self.nativeName = nativeName
    }

    public static let english = Language(code: "en", nativeName: "English")
}

/// The languages that have a catalog, and how the saved setting turns into one of them.
///
/// To add a language, see `docs/localisation.md`: write its `Catalog_xx.swift`, then add it to
/// `all` here and to `Catalog.tables`.
public enum Languages {
    /// The setting value meaning "follow the operating system".
    public static let systemSetting = "system"

    /// Every available language; English first.
    public static let all: [Language] = [.english]

    /// The language to use for a saved setting: a language code, or "system" (or anything that is
    /// no longer available) to follow the operating system's preferred languages, English if none match.
    public static func resolve(_ setting: String, preferred: [String] = Locale.preferredLanguages) -> Language {
        if let exact = all.first(where: { $0.code == setting }) { return exact }
        for identifier in preferred {
            // "de-DE", "de_AT", "zh-Hans-CN" -> the leading language subtag.
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() }
            if let match = all.first(where: { $0.code == code }) { return match }
        }
        return .english
    }
}
