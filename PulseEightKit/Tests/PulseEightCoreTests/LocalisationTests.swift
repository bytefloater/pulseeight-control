import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

/// The catalogs: complete, consistent with English, and resolved from the setting.
@Suite struct CatalogTests {
    @Test func englishHasTextForEveryKeyAndNothingElse() {
        for key in StringKey.allCases {
            let text = Catalog.en[key]
            #expect(text != nil && !text!.isEmpty, "English text missing for \(key.rawValue)")
        }
        #expect(Catalog.en.count == StringKey.allCases.count)
    }

    @Test func keyNamesAreUnique() {
        let names = StringKey.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    @Test func everyLanguageHasEnglishsKeysAndPlaceholders() {
        for language in Languages.all {
            let table = Catalog.tables[language.code]
            #expect(table != nil, "No catalog registered for \(language.code)")
            guard let table else { continue }
            #expect(Set(table.keys) == Set(Catalog.en.keys), "\(language.code) has different keys from English")
            for (key, english) in Catalog.en {
                guard let translated = table[key] else { continue }
                #expect(
                    Strings.placeholders(in: translated) == Strings.placeholders(in: english),
                    "\(language.code) changes the placeholders of \(key.rawValue)")
            }
        }
    }

    @Test func everyCatalogIsAnAvailableLanguageAndEnglishComesFirst() {
        #expect(Languages.all.first == .english)
        #expect(Set(Catalog.tables.keys) == Set(Languages.all.map(\.code)))
    }
}

@Suite struct StringsTests {
    let strings = Strings.english

    @Test func fillsPositionalPlaceholdersInOrder() {
        #expect(strings.text(.routingPortTooltip, "Sky", 1, "OK") == "Sky (port 1) · OK")
        #expect(strings.text(.routingRoute, "A", "B") == "A → B")
    }

    @Test func leavesTextWithoutPlaceholdersAlone() {
        #expect(strings.text(.navSettings) == "Settings")
    }

    @Test func extraArgumentsAreIgnoredAndMissingOnesLeaveTheMarker() {
        #expect(strings.text(.navSettings, "ignored") == "Settings")
        #expect(strings.text(.connectionConnected) == "Connected to {0}")
    }

    @Test func pluralChoosesByCount() {
        #expect(strings.count(1, one: .statusBarFirmwareUpdateOne, other: .statusBarFirmwareUpdateOther) == "1 firmware update")
        #expect(strings.count(3, one: .statusBarFirmwareUpdateOne, other: .statusBarFirmwareUpdateOther) == "3 firmware updates")
        #expect(strings.count(0, one: .statusBarFirmwareUpdateOne, other: .statusBarFirmwareUpdateOther) == "0 firmware updates")
    }

    @Test func aLanguageWithoutACatalogFallsBackToEnglish() {
        let unknown = Strings(language: Language(code: "xx", nativeName: "Testish"))
        #expect(unknown.allText == Strings.english.allText)
    }

    @Test func allTextIsKeyedByTheDottedNames() throws {
        let all = strings.allText
        #expect(all.count == StringKey.allCases.count)
        #expect(all["settings.title"] == "Settings")
        #expect(all["connection.connected"] == "Connected to {0}")
    }

    @Test func placeholdersAreFoundByNumber() {
        #expect(Strings.placeholders(in: "{1} before {0} and {1} again") == [0, 1])
        #expect(Strings.placeholders(in: "no markers, just { braces } here").isEmpty)
    }
}

@Suite struct LanguageResolutionTests {
    @Test func aSavedLanguageCodeWins() {
        #expect(Languages.resolve("en", preferred: ["de-DE"]) == .english)
    }

    @Test func systemFollowsTheFirstSupportedPreferredLanguage() {
        #expect(Languages.resolve("system", preferred: ["fr-FR", "en-GB"]) == .english)
        #expect(Languages.resolve("system", preferred: ["en_US"]) == .english)
        #expect(Languages.resolve("system", preferred: ["EN-gb"]) == .english)
    }

    @Test func systemFallsBackToEnglishWhenNothingMatches() {
        #expect(Languages.resolve("system", preferred: ["ja-JP", "zh-Hans-CN"]) == .english)
        #expect(Languages.resolve("system", preferred: []) == .english)
    }

    @Test func aLanguageThatIsNoLongerAvailableActsLikeSystem() {
        #expect(Languages.resolve("tlh", preferred: ["en-GB"]) == .english)
    }
}

/// The language setting through the core: persistence, the snapshot, the JSON commands.
@Suite struct CoreLanguageTests {
    func makeCore() -> (AppCore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8lang-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        return (AppCore(secrets: MemorySecrets(), settingsURL: url, makeTransport: { _ in FakeTransport() }), url)
    }

    @Test func defaultsToFollowingTheSystem() {
        let (core, _) = makeCore()
        #expect(core.settings.language == "system")
        #expect(core.strings.text(.navSettings) == "Settings")
    }

    @Test func settingsFilesFromBeforeLanguagesStillLoad() throws {
        let (_, url) = makeCore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"appearance":"dark","highlightGrid":false,"showStatusBar":true,"matrix":{"host":"10.0.0.2","port":80}}"#.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        #expect(loaded.language == "system")
        #expect(loaded.appearance == .dark)
    }

    @Test func settingTheLanguagePersistsAndNotifies() throws {
        let (core, url) = makeCore()
        let heard = Heard()
        core.addObserver { _ in heard.increment() }
        try core.setLanguage("en")
        #expect(core.settings.language == "en")
        #expect(AppSettings.load(from: url).language == "en")
        #expect(heard.count == 1)
    }

    @Test func anUnknownLanguageIsRefused() {
        let (core, _) = makeCore()
        #expect(throws: CoreError.self) { try core.setLanguage("tlh") }
        #expect(core.settings.language == "system")
    }

    @Test func theSnapshotListsLanguagesAndSaysWhichIsInForce() throws {
        let (core, _) = makeCore()
        try core.setLanguage("en")
        let snapshot = CoreSnapshot(core: core)
        #expect(snapshot.language == "en")
        #expect(snapshot.settings.language == "en")
        #expect(snapshot.languages == [.init(code: "en", name: "English")])

        let system = AppCore(secrets: MemorySecrets(), settingsURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("p8lang-\(UUID().uuidString)/settings.json"), makeTransport: { _ in FakeTransport() })
        #expect(CoreSnapshot(core: system).settings.language == "system")
    }

    @Test func jsonCommandsSetTheLanguageAndReturnTheTable() async throws {
        let (core, _) = makeCore()
        let ok = await core.handle(requestJSON: #"{"cmd":"setLanguage","value":"en"}"#)
        #expect(ok == #"{"ok":true}"#)
        let bad = await core.handle(requestJSON: #"{"cmd":"setLanguage","value":"tlh"}"#)
        #expect(bad.contains(#""ok":false"#))

        let reply = await core.handle(requestJSON: #"{"cmd":"strings"}"#)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true)
        let table = try #require(JSONSerialization.jsonObject(with: Data((envelope["value"] as? String ?? "").utf8)) as? [String: String])
        #expect(table.count == StringKey.allCases.count)
        #expect(table["settings.title"] == "Settings")
    }

    @Test func coreMessagesComeFromTheCatalog() throws {
        let (core, _) = makeCore()
        #expect(core.connectionSummary == "Not configured")
        #expect(throws: CoreError.invalid("Name can't be empty.")) { try core.validatePortName("  ") }
        #expect(throws: CoreError.invalid("Name must be 13 characters or fewer.")) {
            try core.validatePortName(String(repeating: "x", count: 14))
        }
    }

    @Test func notStartedErrorsAreLocalisedInJSONReplies() async {
        let (core, _) = makeCore()
        let reply = await core.handle(requestJSON: #"{"cmd":"retry"}"#)
        #expect(reply.contains("The matrix connection hasn't been started"))
    }
}

final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
