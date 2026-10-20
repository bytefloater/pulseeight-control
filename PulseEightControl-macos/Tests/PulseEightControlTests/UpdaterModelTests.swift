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
        #expect(AppVersion.description(of: bundle) == "1.2.3 (build 45)")
    }

    @Test func aMissingBuildNumberShowsJustTheVersion() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleShortVersionString": "1.2.3"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "1.2.3")
    }

    private func info(_ short: String, _ build: String, channel: String, label: String) -> [String: Any] {
        ["CFBundleShortVersionString": short, "CFBundleVersion": build, "P8ReleaseChannel": channel, "P8ReleaseLabel": label]
    }

    @Test func aReleaseAReleaseCandidateAndABetaOfOneVersionReadDifferently() throws {
        let cases: [(short: String, build: String, channel: String, label: String, shown: String)] = [
            ("0.1.0", "0.1.0.300", "release", "Release", "0.1.0: Release (build 0.1.0.300)"),
            ("0.1.0-rc.1", "0.1.0.201", "rc", "Release Candidate 1", "0.1.0: Release Candidate 1 (build 0.1.0.201)"),
            ("0.1.0-beta.12", "0.1.0.112", "beta", "Beta 12", "0.1.0: Beta 12 (build 0.1.0.112)"),
        ]
        var seen = Set<String>()
        for c in cases {
            let (bundle, cleanup) = try makeBundle(info: info(c.short, c.build, channel: c.channel, label: c.label))
            defer { cleanup() }
            let shown = AppVersion.description(of: bundle)
            #expect(shown == c.shown)
            seen.insert(shown)
        }
        #expect(seen.count == 3, "no two releases of a version report the same thing")
    }

    @Test func theLabelIsSaidFromTheCatalogNotCopiedFromTheBundle() throws {
        // Whatever English the bundle carries, the words come from the catalog (so they can be translated).
        let (bundle, cleanup) = try makeBundle(info: info("0.1.0-rc.3", "0.1.0.203", channel: "rc", label: "Some English The Build Wrote"))
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "0.1.0: Release Candidate 3 (build 0.1.0.203)")
    }

    @Test func aLabelThatCannotBeRebuiltIsShownAsItIs() throws {
        let (bundle, cleanup) = try makeBundle(info: info("0.1.0-gamma.2", "0.1.0.250", channel: "gamma", label: "Gamma 2"))
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "0.1.0: Gamma 2 (build 0.1.0.250)")
    }

    @Test func aMissingBuildLeavesJustTheVersionAndLabel() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleShortVersionString": "0.1.0", "P8ReleaseChannel": "release", "P8ReleaseLabel": "Release"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "0.1.0: Release")
    }

    @Test func aPackagedDevelopmentBuildIsStillADevelopmentBuild() throws {
        let (bundle, cleanup) = try makeBundle(info: info("0.0.0-dev", "0.0.0.0", channel: "dev", label: "Development build"))
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "Development build")
    }

    @Test func theChannelOfABundleSaysWhetherItIsAPreRelease() throws {
        for (channel, expected) in [("release", false), ("rc", true), ("beta", true), ("dev", false), (" RC ", true)] {
            let (bundle, cleanup) = try makeBundle(info: info("0.1.0", "0.1.0.201", channel: channel, label: "x"))
            defer { cleanup() }
            #expect(AppVersion.isPrerelease(of: bundle) == expected, "\(channel)")
        }
        let (plain, cleanup) = try makeBundle(info: ["CFBundleShortVersionString": "1.2.3"])
        defer { cleanup() }
        #expect(!AppVersion.isPrerelease(of: plain), "a bundle that doesn't say is a release")
    }

    @Test func anUnpackagedRunIsADevelopmentBuild() throws {
        let (bundle, cleanup) = try makeBundle(named: "Tool.xctest", info: ["CFBundleShortVersionString": "9.9.9"])
        defer { cleanup() }
        #expect(AppVersion.description(of: bundle) == "Development build")
        #expect(AppVersion.description() == "Development build")
    }
}

@MainActor
@Suite struct UpdateChannelTests {
    @Test func preReleasesOffMeansTheDefaultChannelOnly() {
        #expect(UpdaterModel.channels(includePrereleases: false).isEmpty, "a release has no channel and is always offered")
    }

    @Test func preReleasesOnAddsBothPreReleaseChannels() {
        #expect(UpdaterModel.channels(includePrereleases: true) == ["rc", "beta"])
    }

    @Test func theChoiceStartsFromTheInstalledBuild() throws {
        for (channel, expected) in [("release", false), ("rc", true), ("beta", true), ("dev", false)] {
            let info: [String: Any] = ["CFBundleIdentifier": "x.y", "P8ReleaseChannel": channel]
            let (bundle, cleanup) = try makeBundle(info: info)
            defer { cleanup() }
            let updater = UpdaterModel(bundle: bundle)
            #expect(updater.buildIsPrerelease == expected, "\(channel)")
            #expect(updater.includePrereleases == expected, "\(channel): a beta keeps getting betas until the person says otherwise")
        }
    }

    @Test func theChoiceCanBeChangedAndTheModelStaysSafeWithoutAFeed() throws {
        let (bundle, cleanup) = try makeBundle(info: ["CFBundleIdentifier": "x.y", "P8ReleaseChannel": "release"])
        defer { cleanup() }
        let updater = UpdaterModel(bundle: bundle)
        updater.includePrereleases = true
        #expect(updater.includePrereleases)
        updater.includePrereleases = false
        #expect(!updater.includePrereleases)
    }
}
