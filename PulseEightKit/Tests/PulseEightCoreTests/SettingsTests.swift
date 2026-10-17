import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

private func scratchFile(_ name: String = "settings.json") throws -> (url: URL, cleanup: () -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p8-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder.appendingPathComponent(name), { try? FileManager.default.removeItem(at: folder) })
}

@Suite struct SettingsFileTests {
    @Test func updateChecksDefaultOnAndSurviveARoundTrip() throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        #expect(AppSettings().checkForUpdates)

        var settings = AppSettings()
        settings.checkForUpdates = false
        try settings.save(to: url)
        #expect(AppSettings.load(from: url).checkForUpdates == false)
    }

    @Test func aSettingsFileFromBeforeUpdatesExistedStillLoadsWithChecksOn() throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        try Data(#"{"matrix":{"host":"10.0.0.9"},"appearance":"dark"}"#.utf8).write(to: url)
        let settings = AppSettings.load(from: url)
        #expect(settings.checkForUpdates)
        #expect(settings.matrix.host == "10.0.0.9")
    }

    @Test func aMissingFileGivesDefaults() throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        #expect(AppSettings.load(from: url) == AppSettings())
    }

    @Test(arguments: ["", "   ", "{", "not json at all", "[]", "null", "42"])
    func anUnreadableFileGivesDefaults(contents: String) throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        try Data(contents.utf8).write(to: url)
        #expect(AppSettings.load(from: url) == AppSettings())
    }

    @Test func savingThenLoadingGivesTheSameSettings() throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        var settings = AppSettings()
        settings.matrix = MatrixConfig(host: "192.168.1.150", port: 8080, timeout: 3, pollInterval: 2, detailPollInterval: 9)
        settings.appearance = .dark
        settings.highlightGrid = false
        settings.showStatusBar = false
        settings.language = "en"

        try settings.save(to: url)
        #expect(AppSettings.load(from: url) == settings)
    }

    @Test func savingCreatesMissingFoldersAndLeavesNothingElseBehind() throws {
        let (url, cleanup) = try scratchFile("nested/deeper/settings.json")
        defer { cleanup() }
        try AppSettings().save(to: url)
        try AppSettings().save(to: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["settings.json"])
    }

    /// Sorted, indented keys: a settings file you hand-edit or put under version control diffs sensibly.
    @Test func theFileIsStableAndReadable() throws {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        try AppSettings().save(to: url)
        let first = try String(contentsOf: url, encoding: .utf8)
        try AppSettings().save(to: url)

        #expect(first == (try String(contentsOf: url, encoding: .utf8)))
        #expect(first.contains("\n  \"appearance\""))
        let keys = ["appearance", "highlightGrid", "language", "matrix", "showStatusBar"]
        #expect(keys.compactMap { first.range(of: "\"\($0)\"")?.lowerBound } == keys.compactMap { first.range(of: "\"\($0)\"")?.lowerBound }.sorted())
    }
}

/// One value this version can't read must not cost the user the rest of the file: above all the matrix's
/// host, which they would have to retype.
@Suite struct SettingsToleranceTests {
    func load(_ json: String) throws -> AppSettings {
        let (url, cleanup) = try scratchFile()
        defer { cleanup() }
        try Data(json.utf8).write(to: url)
        return AppSettings.load(from: url)
    }

    @Test func missingFieldsTakeTheirDefaults() throws {
        let settings = try load(#"{"appearance":"dark"}"#)
        #expect(settings.appearance == .dark)
        #expect(settings.matrix == MatrixConfig())
        #expect(settings.highlightGrid && settings.showStatusBar)
    }

    @Test func unknownKeysAreIgnored() throws {
        let settings = try load(#"{"matrix":{"host":"10.0.0.9"},"somethingFromTheFuture":{"a":1},"appearance":"light"}"#)
        #expect(settings.matrix.host == "10.0.0.9")
        #expect(settings.appearance == .light)
    }

    @Test func anAppearanceFromANewerVersionKeepsTheHost() throws {
        let settings = try load(#"{"matrix":{"host":"10.0.0.9","port":8080},"appearance":"highContrast"}"#)
        #expect(settings.appearance == .system)
        #expect(settings.matrix.host == "10.0.0.9")
        #expect(settings.matrix.port == 8080)
    }

    @Test func aWrongTypedUpdateFlagKeepsTheDefaultAndEverythingElse() throws {
        let settings = try load(#"{"matrix":{"host":"10.0.0.9"},"checkForUpdates":"nope","appearance":"dark"}"#)
        #expect(settings.checkForUpdates)
        #expect(settings.matrix.host == "10.0.0.9")
        #expect(settings.appearance == .dark)
    }

    @Test func aWrongTypedFlagKeepsEverythingElse() throws {
        let settings = try load(#"{"matrix":{"host":"10.0.0.9"},"highlightGrid":"yes","showStatusBar":false}"#)
        #expect(settings.highlightGrid == true) // default
        #expect(settings.showStatusBar == false)
        #expect(settings.matrix.host == "10.0.0.9")
    }

    @Test func aBadPortKeepsTheHostAndTheOtherNumbers() throws {
        let settings = try load(#"{"matrix":{"host":"10.0.0.9","port":"eighty","timeout":3}}"#)
        #expect(settings.matrix.host == "10.0.0.9")
        #expect(settings.matrix.port == 80)
        #expect(settings.matrix.timeout == 3)
    }

    @Test func aMatrixThatIsNotAnObjectFallsBackToTheDefaultMatrix() throws {
        let settings = try load(#"{"matrix":"10.0.0.9","appearance":"dark"}"#)
        #expect(settings.matrix == MatrixConfig())
        #expect(settings.appearance == .dark)
    }
}
