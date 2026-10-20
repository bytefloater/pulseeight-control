import Foundation
import Observation
import PulseEightCore
import Sparkle

/// What this build calls itself, for the Settings pane and the update prompts. A build's version comes from its release tag
/// (scripts/release/version.py) and is written into the bundle when it is packaged: the version people see, what updaters
/// compare, and a channel and label that tell a release, a release candidate and a beta of one version apart.
enum AppVersion {
    /// "release", "rc" or "beta" for a packaged release; "dev" for a development build. A bundle that doesn't say is a release.
    static func channel(of bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "P8ReleaseChannel") as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? "release"
    }

    /// Whether this is a release candidate or a beta, which is what an update setting that is left unset follows.
    static func isPrerelease(of bundle: Bundle = .main) -> Bool {
        ["rc", "beta"].contains(channel(of: bundle))
    }

    /// "0.1.0: Release Candidate 1 (build 0.1.0.201)", "0.1.0: Release (build 0.1.0.300)" or "Development build", in the
    /// language in force.
    static func description(of bundle: Bundle = .main, strings: Strings = .english) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard bundle.bundleURL.pathExtension == "app", let short, channel(of: bundle) != "dev" else {
            return strings.text(.versionDevelopment)
        }
        if let label = bundle.object(forInfoDictionaryKey: "P8ReleaseLabel") as? String, !label.isEmpty {
            // The version without its -rc.1: the label says which one it is.
            let version = short.split(separator: "-").first.map(String.init) ?? short
            let shown = releaseLabel(channel: channel(of: bundle), short: short, fallback: label, strings)
            guard let build else { return strings.text(.versionNoBuild, version, shown) }
            return strings.text(.versionFormat, version, shown, build)
        }
        // A bundle from before labels: the version and build as they are.
        guard let build else { return short }
        return strings.text(.versionPlain, short, build)
    }

    /// "Release", "Release Candidate 1" or "Beta 3", from the channel and the number in the version (0.1.0-rc.1), so it can be
    /// said in any language. A label the bundle carries that this can't rebuild is shown as it is.
    static func releaseLabel(channel: String, short: String, fallback: String, _ strings: Strings) -> String {
        let number = short.split(separator: "-").dropFirst().first.flatMap { $0.split(separator: ".").last }.flatMap { Int($0) }
        switch (channel, number) {
        case ("release", _): return strings.text(.versionRelease)
        case ("rc", let number?): return strings.text(.versionReleaseCandidate, number)
        case ("beta", let number?): return strings.text(.versionBeta, number)
        default: return fallback
        }
    }
}

/// Automatic updates, through Sparkle.
///
/// Only active in the packaged app, and only when that app knows where to look: a feed URL and the public
/// key that updates must be signed with (`SUFeedURL`, `SUPublicEDKey`). Both are put into the built app's
/// Info.plist when it is packaged (see PulseEightControl-macos/package.sh), never kept in the source, so a
/// development run (`swift run`, Xcode) stays quiet and nothing can update a build that has no key to check against.
@MainActor
@Observable
final class UpdaterModel {
    private let controller: SPUStandardUpdaterController?
    private let delegate: Delegate
    private var observation: NSKeyValueObservation?

    /// Whether this build can update at all (see the type's note).
    let isAvailable: Bool

    /// Whether this build is a release candidate or a beta: what the pre-release choice follows until the person makes one.
    let buildIsPrerelease: Bool

    /// Whether the feed's release candidates and betas are offered as well as releases. The app keeps it in step with the
    /// setting (or with `buildIsPrerelease` while that is unset); Sparkle asks the delegate at each check.
    var includePrereleases: Bool {
        didSet { delegate.setIncludePrereleases(includePrereleases) }
    }

    /// The feed channels an update may come from. A release has none, so it is always offered; a release candidate or beta
    /// names `rc` or `beta`, and is offered only when pre-releases are on. Sparkle and the Windows updater work the same way.
    nonisolated static func channels(includePrereleases: Bool) -> Set<String> {
        includePrereleases ? ["rc", "beta"] : []
    }

    /// False while a check or an installation is already under way.
    private(set) var canCheckForUpdates = false

    /// When Sparkle last asked the feed; nil if never, or when updates aren't available.
    private(set) var lastChecked: Date?

    /// Whether Sparkle checks on its own schedule (about daily). Setting it is remembered by Sparkle.
    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    init(bundle: Bundle = .main) {
        let prerelease = AppVersion.isPrerelease(of: bundle)
        delegate = Delegate(includePrereleases: prerelease)
        buildIsPrerelease = prerelease
        includePrereleases = prerelease
        guard Self.isConfigured(bundle) else {
            controller = nil
            isAvailable = false
            automaticallyChecks = false
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        lastChecked = controller.updater.lastUpdateCheckDate

        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
        delegate.onCycleFinished = { [weak self] in
            Task { @MainActor in self?.refreshLastChecked() }
        }
    }

    /// True for an app bundle that carries both a feed URL and a public key.
    static func isConfigured(_ bundle: Bundle) -> Bool {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return bundle.bundleURL.pathExtension == "app" && !value("SUFeedURL").isEmpty && !value("SUPublicEDKey").isEmpty
    }

    /// Asks the feed now and shows Sparkle's own window with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func refreshLastChecked() {
        lastChecked = controller?.updater.lastUpdateCheckDate
    }

    /// Sparkle's delegate must be an NSObject; this only reports that a check finished.
    private final class Delegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
        var onCycleFinished: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var prereleases: Bool

        init(includePrereleases: Bool) {
            prereleases = includePrereleases
        }

        func setIncludePrereleases(_ on: Bool) {
            lock.lock(); defer { lock.unlock() }
            prereleases = on
        }

        /// Asked on Sparkle's own thread at every check.
        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            return UpdaterModel.channels(includePrereleases: prereleases)
        }

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
            onCycleFinished?()
        }
    }
}
