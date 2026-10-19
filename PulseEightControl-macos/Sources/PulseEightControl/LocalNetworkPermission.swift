import AppKit
import Network
import Observation

/// macOS asks, per app, before letting it talk to devices on the local network (a matrix, say). There is no
/// call to request that permission: the question appears the first time the app touches the local network, and
/// until it is answered every connection fails as "The Internet connection appears to be offline".
///
/// This asks on purpose, early, and learns the answer, by browsing for Bonjour `_http._tcp` services (the type is
/// declared in Info.plist as NSBonjourServices, which the browse needs). The browse is how Apple's own guidance
/// says to find out: it goes `.ready` once the app is allowed, and `.waiting` with a policy-denied DNS error
/// when it isn't. The app then reconnects the moment the answer is yes, instead of at the next poll.
@MainActor
@Observable
final class LocalNetworkPermission {
    enum State: Equatable {
        /// Not asked yet, or no answer came.
        case unknown
        /// The question is on screen (or about to be).
        case asking
        case granted
        case denied
    }

    private(set) var state: State = .unknown
    /// Called when the answer changes to yes, so the app can connect without waiting for its next poll.
    var onGranted: (() -> Void)?

    private let enabled: Bool
    private var browser: NWBrowser?
    private var timeout: Task<Void, Never>?

    /// A permission that never asks, for tests and for matrices on this Mac (`127.0.0.1`).
    static var disabled: LocalNetworkPermission { LocalNetworkPermission(enabled: false) }

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        // Back from System Settings (where it may have been switched on): ask again.
        // It lives as long as the app does, so the observer is never removed.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .granted, self.state != .asking else { return }
                self.check()
            }
        }
    }

    /// Asks (or finds out) now. Cheap once the permission has been granted.
    func check() {
        guard enabled, state != .granted else { return }
        browser?.cancel()
        timeout?.cancel()
        state = .asking

        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: NWParameters())
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in self?.handle(browserState) }
        }
        browser.start(queue: .main)
        // The question can sit unanswered for a long time; don't pretend to know.
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.unknown)
        }
    }

    /// What a browser state says about the permission, or nil if it says nothing yet.
    nonisolated static func answer(for browserState: NWBrowser.State) -> State? {
        switch browserState {
        case .ready:
            return .granted
        case .waiting(let error), .failed(let error):
            // kDNSServiceErr_PolicyDenied: the user said no (or the permission is off in System Settings).
            if case .dns(let code) = error, code == -65570 { return .denied }
            return nil
        default:
            return nil
        }
    }

    private func handle(_ browserState: NWBrowser.State) {
        if let answer = Self.answer(for: browserState) { finish(answer) }
    }

    private func finish(_ answer: State) {
        timeout?.cancel()
        browser?.cancel()
        browser = nil
        let wasGranted = state == .granted
        state = answer
        if answer == .granted, !wasGranted { onGranted?() }
    }
}
