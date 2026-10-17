import Foundation
import Observation
import Sparkle

/// What this build calls itself, for the Settings pane and the update prompts.
enum AppVersion {
    static func description(of bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard bundle.bundleURL.pathExtension == "app", let short else { return "Development build" }
        guard let build, !build.isEmpty else { return short }
        return "\(short) (\(build))"
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
    private let delegate = Delegate()
    private var observation: NSKeyValueObservation?

    /// Whether this build can update at all (see the type's note).
    let isAvailable: Bool

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

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
            onCycleFinished?()
        }
    }
}
