import Foundation

/// The text tables, one per language. English is the reference; see `Languages.all`.
enum Catalog {
    /// Language code -> text. Add a language by adding its table here (and to `Languages.all`).
    static let tables: [String: [StringKey: String]] = [
        "en": en,
    ]
}

/// Looks text up in one language. A value type: the core hands out a `Strings` for the language
/// currently in force, and a UI just asks it for keys. A key missing from the language falls back to
/// English, so a half-finished translation never shows a blank.
public struct Strings: Sendable {
    public let language: Language
    private let table: [StringKey: String]

    public init(language: Language = .english) {
        self.language = language
        var merged = Catalog.en
        if let own = Catalog.tables[language.code] { merged.merge(own) { _, translated in translated } }
        table = merged
    }

    public static let english = Strings(language: .english)

    /// The text for a key.
    public func text(_ key: StringKey) -> String {
        table[key] ?? key.rawValue
    }

    /// The text for a key with `{0}`, `{1}`... replaced by the arguments, in order.
    public func text(_ key: StringKey, _ arguments: any CustomStringConvertible...) -> String {
        Strings.fill(text(key), arguments.map { String(describing: $0) })
    }

    /// `one` when the count is 1, otherwise `other` (given the count as `{0}`). Languages with more
    /// plural forms will need a richer rule here when one is added.
    public func count(_ n: Int, one: StringKey, other: StringKey) -> String {
        n == 1 ? text(one) : text(other, n)
    }

    /// The whole table by dotted key, for clients of the C interface.
    public var allText: [String: String] {
        Dictionary(uniqueKeysWithValues: StringKey.allCases.map { ($0.rawValue, text($0)) })
    }

    static func fill(_ template: String, _ arguments: [String]) -> String {
        guard template.contains("{") else { return template }
        var result = template
        for (index, argument) in arguments.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return result
    }

    /// The `{n}` placeholders a template uses, for the consistency tests.
    static func placeholders(in template: String) -> Set<Int> {
        var found = Set<Int>()
        var index = template.startIndex
        while let open = template[index...].firstIndex(of: "{") {
            guard let close = template[open...].firstIndex(of: "}") else { break }
            if let number = Int(template[template.index(after: open)..<close]) { found.insert(number) }
            index = template.index(after: close)
        }
        return found
    }
}
