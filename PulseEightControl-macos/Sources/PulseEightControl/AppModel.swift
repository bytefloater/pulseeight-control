import Foundation
import PulseEightCore
import PulseEightKit
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

enum Page: String, CaseIterable, Identifiable, CustomStringConvertible {
    case routing, hardware

    var id: String { rawValue }
    var description: String { rawValue.capitalized }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case matrix, admin, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: "Matrix"
        case .admin: "Admin"
        case .appearance: "Appearance"
        }
    }

    /// SF Symbol name for the Settings sidebar.
    var symbol: String {
        switch self {
        case .matrix: "network"
        case .admin: "lock"
        case .appearance: "paintbrush"
        }
    }
}

struct RouteKey: Hashable {
    var input: Int
    var output: Int
}

struct PortSelection: Equatable {
    var mode: PortMode
    var bay: Int
}

/// Rename + EDID form in the port sheet.
struct PortEditDraft: Equatable {
    var name = ""
    var edidProfile: Int?
    var error: String?
    var saving = false
}

/// Text fields in the Settings window, kept as strings until Apply validates them.
struct SettingsDraft: Equatable {
    var host = ""
    var port = "80"
    var timeout = "10"
    var pollInterval = "5"
    var detailPollInterval = "20"
    /// Blank means "keep what is saved".
    var adminPassword = ""
    var appearance: Appearance = .system

    init() {}

    init(_ settings: AppSettings) {
        host = settings.matrix.host ?? ""
        port = String(settings.matrix.port)
        timeout = String(settings.matrix.timeout)
        pollInterval = String(settings.matrix.pollInterval)
        detailPollInterval = String(settings.matrix.detailPollInterval)
        appearance = settings.appearance
    }

    var input: SettingsInput {
        SettingsInput(
            host: host, port: port, timeout: timeout, pollInterval: pollInterval,
            detailPollInterval: detailPollInterval, adminPassword: adminPassword
        )
    }
}

/// Observable wrapper over the shared `AppCore` (settings, connection, commands) for the views, plus
/// the state that only the macOS UI has: which page is showing, open sheets, drafts, and controls
/// waiting for the matrix to confirm a change.
@MainActor
@Observable
final class AppModel {
    /// nil until the matrix has been reached. Changes whenever anything but poll timestamps does.
    var state: MatrixState?
    /// Just the port list, assigned only when it actually changes. The routing grid reads this so
    /// a routine poll doesn't rebuild ~270 views.
    var ports: [MatrixPort] = []
    /// Firmware updates available; stored for the same reason as `ports` (the window chrome reads it).
    private(set) var updateCount = 0
    private(set) var settings: AppSettings
    /// Stored (not derived) so views that only need to know "connected or not" don't re-run on
    /// every update.
    private(set) var phase: ConnectionPhase
    private(set) var adminConfigured = false

    var draft: SettingsDraft
    var page: Page? = .routing
    var settingsPane: SettingsPane = .matrix
    /// Set by MacChrome; opens (or raises) the Settings window.
    var openSettingsWindow: (() -> Void)?
    /// Result of the last Settings save: (text, isError).
    var settingsMessage: (text: String, isError: Bool)?
    var retrying = false
    /// Routes sent to the matrix that haven't been confirmed by a poll yet.
    var pendingRoutes: Set<RouteKey> = []
    /// Set when a route request fails; the Routing page shows it in an alert.
    var routeError: String?
    /// The port whose detail sheet is open.
    var selectedPort: PortSelection?
    var portEdit = PortEditDraft()
    /// Front panel controls hold their new value here until the matrix confirms it, so an update
    /// landing mid-request doesn't flip the control back.
    var backlightPending: BacklightLevel?
    var statusLEDPending: Bool?
    var frontPanelError: String?

    let core: AppCore

    init(core: AppCore = AppCore()) {
        self.core = core
        settings = core.settings
        phase = core.phase
        draft = SettingsDraft(core.settings)
    }

    // MARK: Derived state

    var connectionSummary: String { core.connectionSummary }
    var hostLabel: String { core.hostLabel }

    /// Short form for the window chrome; the host is in Settings.
    var connectionShort: String {
        switch phase {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .notConfigured: "Not configured"
        case .disconnected: "Not connected"
        }
    }

    /// Changes whenever something the native window chrome shows changes.
    var chromeSignature: String {
        "\(page?.rawValue ?? "")|\(updateCount)"
    }

    var inputs: [MatrixPort] { ports.filter { $0.mode == .input }.sorted { $0.bay < $1.bay } }
    var outputs: [MatrixPort] { ports.filter { $0.mode == .output }.sorted { $0.bay < $1.bay } }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        core.addObserver { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        await core.start()
    }

    private var started = false

    /// Each assignment only happens when the value changed: assigning an observable property
    /// notifies its readers even when the value is equal, and in SwiftCrossUI that ripples up
    /// through every ancestor view.
    private func apply(_ update: CoreUpdate) {
        if update.state != state { state = update.state }
        let newPorts = update.state?.ports ?? []
        if newPorts != ports { ports = newPorts }
        let count = update.state?.updates.count ?? 0
        if count != updateCount { updateCount = count }
        if update.settings != settings { settings = update.settings }
        if update.phase != phase { phase = update.phase }
        if update.adminConfigured != adminConfigured { adminConfigured = update.adminConfigured }
    }

    // MARK: Actions

    /// Poll right now instead of waiting for the next tick. Used by "Retry now" and the Matrix menu.
    func retry() {
        guard !retrying else { return }
        retrying = true
        Task {
            try? await core.retry()
            retrying = false
        }
    }

    /// Drop the connection and start again from the saved settings.
    func reconnect() {
        core.reconnect()
    }

    func route(input: Int, output: Int) {
        let key = RouteKey(input: input, output: output)
        guard !pendingRoutes.contains(key) else { return }
        pendingRoutes.insert(key)
        Task {
            do {
                try await core.route(input: input, output: output)
            } catch {
                routeError = "Failed to set route: \(error.localizedDescription)"
            }
            pendingRoutes.remove(key)
        }
    }

    // MARK: Port editing

    func openPort(_ selection: PortSelection) {
        guard let state else { return }
        let port = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }
        portEdit = PortEditDraft(
            name: port?.name ?? "",
            edidProfile: selection.mode == .input ? state.inputDetails[selection.bay]?.edidProfile : nil
        )
        selectedPort = selection
    }

    func savePortEdit() {
        guard let selection = selectedPort, let state, !portEdit.saving else { return }
        let name: String
        do {
            name = try core.validatePortName(portEdit.name)
        } catch {
            return portEdit.error = error.localizedDescription
        }
        let current = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }?.name
        let currentEdid = selection.mode == .input ? state.inputDetails[selection.bay]?.edidProfile : nil
        let newEdid = selection.mode == .input ? portEdit.edidProfile : nil

        portEdit.error = nil
        portEdit.saving = true
        Task {
            do {
                if name != current {
                    try await core.renamePort(mode: selection.mode, bay: selection.bay, name: name)
                }
                if let newEdid, newEdid != currentEdid {
                    try await core.setEdidProfile(bay: selection.bay, profile: newEdid)
                }
                portEdit.name = name
            } catch {
                portEdit.error = error.localizedDescription
            }
            portEdit.saving = false
        }
    }

    // MARK: Front panel

    func setBacklight(_ level: BacklightLevel) {
        guard backlightPending == nil else { return }
        frontPanelError = nil
        backlightPending = level
        Task {
            do {
                try await core.setBacklight(level)
                await waitForState { $0.system?.features.backlight == level }
            } catch {
                frontPanelError = error.localizedDescription
            }
            backlightPending = nil
        }
    }

    func setStatusLED(on: Bool) {
        guard statusLEDPending == nil else { return }
        frontPanelError = nil
        statusLEDPending = on
        Task {
            do {
                try await core.setStatusLED(on: on)
                await waitForState { $0.system?.features.statusLEDOn == on }
            } catch {
                frontPanelError = error.localizedDescription
            }
            statusLEDPending = nil
        }
    }

    /// The matrix refreshes system info shortly after a write; give it a few seconds.
    private func waitForState(_ condition: (MatrixState) -> Bool) async {
        for _ in 0..<30 {
            if let state, condition(state) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: View preferences

    func setHighlightGrid(_ on: Bool) {
        core.setHighlightGrid(on)
    }

    func setShowStatusBar(_ on: Bool) {
        core.setShowStatusBar(on)
    }

    /// Appearance applies immediately; the other fields wait for Apply.
    func setAppearance(_ appearance: Appearance) {
        draft.appearance = appearance
        core.setAppearance(appearance)
    }

    // MARK: Settings window

    func openSettings() {
        openSettingsWindow?()
    }

    /// Discards unsaved edits; called each time the Settings window opens.
    func resetDraft() {
        draft = SettingsDraft(core.settings)
        settingsMessage = nil
    }

    func saveSettings() {
        settingsMessage = nil
        do {
            try core.saveSettings(draft.input)
        } catch {
            settingsMessage = (error.localizedDescription, true)
            return
        }
        draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.adminPassword = ""
        settingsMessage = ("Saved.", false)
    }

    func removeAdminPassword() {
        do {
            try core.removeAdminPassword()
        } catch {
            settingsMessage = (error.localizedDescription, true)
            return
        }
        draft.adminPassword = ""
        settingsMessage = ("Admin password removed.", false)
    }
}
