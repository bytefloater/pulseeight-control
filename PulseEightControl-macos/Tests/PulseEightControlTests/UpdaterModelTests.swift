import Foundation
import Testing
@testable import PulseEightControl

/// A bundle laid out on disk as `<name>.app/Contents/Info.plist`, so `Bundle` reads real Info.plist keys.
private func makeBundle(named name: String = "Test.app", info: [String: Any]) throws -> (bundle: Bundle, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p8bundle-\(UUID().uuidString)", isDirectory: true)
    let contents = root.appendingPathComponent("\(name)/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: root.appendingPathComponent(name)))
    return (bundle, { try? FileManager.default.removeItem(at: root) })
}

@MainActor
@Suite struct UpdaterConfigurationTests {
    static let key = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE="
    static let feed = "https://example.com/appcast.xml"

    @Test func aBundleWithAFeedAndAKeyIsConfigured() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleIdentifier": "x.y", "SUFeedURL": Self.feed, "SUPublicEDKey": Self.key])
        defer { cleanup() }
        #expect(UpdaterModel.isConfigured(bundle))
    }

    @Test(arguments: [
        ["SUFeedURL": "https://example.com/appcast.xml"],
        ["SUPublicEDKey": "AbCdEf"],
        ["SUFeedURL": "", "SUPublicEDKey": "AbCdEf"],
        ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "   "],
        [:],
    ])
    func aBundleMissingEitherIsNot(extra: [String: String]) throws {
        var info: [String: Any] = ["CFBundleIdentifier": "x.y"]
        for (key, value) in extra { info[key] = value }
        let (bundle, cleanup) = try makeBundle(info: info)
        defer { cleanup() }
        #expect(!UpdaterModel.isConfigured(bundle))
    }

    /// An unbundled run (`swift run`, a test runner) is never configured, even if the keys were somehow present.
    @Test func onlyAnAppBundleCanUpdateItself() throws {
        let (bundle, cleanup) = try makeBundle(named: "Tool.xctest", info: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key])
        defer { cleanup() }
        #expect(!UpdaterModel.isConfigured(bundle))
        #expect(!UpdaterModel.isConfigured(.main), "the test process must never start Sparkle")
    }

    @Test func anUnconfiguredModelIsInertAndSafeToUse() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleIdentifier": "x.y"])
        defer { cleanup() }
        let updater = UpdaterModel(bundle: bundle)

        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticallyChecks)
        #expect(updater.lastChecked == nil)
        updater.checkForUpdates() // no controller: must do nothing, not crash
        updater.automaticallyChecks = true // nothing to forward to
    }
}

@Suite struct AppVersionTests {
    @Test func aPackagedAppShowsVersionAndBuild() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "1.2.3 (45)")
    }

    @Test func aMissingBuildNumberShowsJustTheVersion() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleShortVersionString": "1.2.3"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "1.2.3")
    }

    @Test func anUnpackagedRunIsADevelopmentBuild() throws {
        let (bundle, cleanup) = try makeBundle(named: "Tool.xctest", info: ["CFBundleShortVersionString": "9.9.9"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "Development build")
        #expect(AppVersion.description() == "Development build")
    }
}
