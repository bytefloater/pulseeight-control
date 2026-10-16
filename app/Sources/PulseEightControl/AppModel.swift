import Foundation
import PulseEightKit
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

enum Page: String, CaseIterable, Identifiable, CustomStringConvertible {
    case routing, hardware, settings

    var id: String { rawValue }
    var description: String { rawValue.capitalized }
}

enum ConnectionPhase: Equatable {
    case notConfigured
    case connecting
    case connected
    case disconnected(String?)
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

/// Text fields in the Settings page, kept as strings until Save validates them.
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
}

/// Bridges `MatrixStore` (an actor) to the views.
@MainActor
@Observable
final class AppModel {
    static let adminAccount = "admin-password"

    /// nil until the store has published for the first time.
    var state: MatrixState?
    var settings: AppSettings
    var draft: SettingsDraft
    var page: Page? = .routing
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
    /// Front panel controls hold their new value here until the matrix confirms it, so a poll
    /// landing mid-request doesn't flip the control back.
    var backlightPending: BacklightLevel?
    var statusLEDPending: Bool?
    var frontPanelError: String?

    private let secrets: SecretStore
    private var store: MatrixStore?

    init(secrets: SecretStore = SecretStores.makeDefault()) {
        let settings = AppSettings.load()
        self.secrets = secrets
        self.settings = settings
        self.draft = SettingsDraft(settings)
        if settings.matrix.host?.isEmpty != false { page = .settings }
    }

    // MARK: Derived state

    var phase: ConnectionPhase {
        guard let status = state?.status else {
            return settings.matrix.host?.isEmpty == false ? .connecting : .notConfigured
        }
        if !status.configured { return .notConfigured }
        if status.connected { return .connected }
        if status.lastPollTime == nil && status.error == nil { return .connecting }
        return .disconnected(status.error)
    }

    var adminConfigured: Bool { state?.adminConfigured ?? false }

    /// One line for the window subtitle (macOS) or footer (elsewhere).
    var connectionSummary: String {
        switch phase {
        case .connected: "Connected to \(hostLabel)"
        case .connecting: "Connecting to \(hostLabel)…"
        case .notConfigured: "Not configured"
        case .disconnected: "Not connected to \(hostLabel)"
        }
    }

    /// Short form for the macOS title bar; the host is in Settings.
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
        "\(page?.rawValue ?? "")|\(connectionShort)|\(state?.updates.count ?? 0)"
    }

    var hostLabel: String {
        guard let host = settings.matrix.host, !host.isEmpty else { return "no host" }
        return settings.matrix.port == 80 ? host : "\(host):\(settings.matrix.port)"
    }

    // MARK: Lifecycle

    func start() async {
        guard store == nil else { return }
        let password = (try? secrets.secret(for: Self.adminAccount)) ?? nil
        let store = MatrixStore(config: settings.matrix, adminPassword: password) { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        self.store = store
        await store.start()
    }

    // MARK: Actions

    /// Poll right now instead of waiting for the next tick. Used by "Retry now" and the Matrix menu.
    func retry() {
        guard let store, !retrying else { return }
        retrying = true
        Task {
            try? await store.reconnect()
            retrying = false
        }
    }

    func route(input: Int, output: Int) {
        let key = RouteKey(input: input, output: output)
        guard let store, !pendingRoutes.contains(key) else { return }
        pendingRoutes.insert(key)
        Task {
            do {
                try await store.setPort(input: input, output: output)
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
        guard let store, let selection = selectedPort, let state, !portEdit.saving else { return }
        let name = portEdit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return portEdit.error = "Name can't be empty." }
        guard name.unicodeScalars.count <= AdminClient.maxNameLength else {
            return portEdit.error = "Name must be \(AdminClient.maxNameLength) characters or fewer."
        }
        let current = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }?.name
        let currentEdid = selection.mode == .input ? state.inputDetails[selection.bay]?.edidProfile : nil
        let newEdid = selection.mode == .input ? portEdit.edidProfile : nil

        portEdit.error = nil
        portEdit.saving = true
        Task {
            do {
                if name != current {
                    try await store.renamePort(mode: selection.mode, bay: selection.bay, name: name)
                }
                if let newEdid, newEdid != currentEdid {
                    try await store.setEdidProfile(bay: selection.bay, profile: newEdid)
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
        guard let store, backlightPending == nil else { return }
        frontPanelError = nil
        backlightPending = level
        Task {
            do {
                try await store.setBacklight(level)
                await waitForState { $0.system?.features.backlight == level }
            } catch {
                frontPanelError = error.localizedDescription
            }
            backlightPending = nil
        }
    }

    func setStatusLED(on: Bool) {
        guard let store, statusLEDPending == nil else { return }
        frontPanelError = nil
        statusLEDPending = on
        Task {
            do {
                try await store.setStatusLED(on: on)
                await waitForState { $0.system?.features.statusLEDOn == on }
            } catch {
                frontPanelError = error.localizedDescription
            }
            statusLEDPending = nil
        }
    }

    /// The store refreshes system info shortly after a write; give it a few seconds.
    private func waitForState(_ condition: (MatrixState) -> Bool) async {
        for _ in 0..<30 {
            if let state, condition(state) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func openSettings() {
        page = .settings
    }

    func saveSettings() {
        settingsMessage = nil
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return fail("Enter the matrix's IP address or hostname.") }
        guard let port = Int(draft.port), (1...65535).contains(port) else {
            return fail("Port must be a number from 1 to 65535.")
        }
        guard let timeout = Int(draft.timeout), timeout >= 1 else { return fail("Timeout must be at least 1 second.") }
        guard let poll = Int(draft.pollInterval), poll >= 1 else { return fail("Poll interval must be at least 1 second.") }
        guard let detail = Int(draft.detailPollInterval), detail >= 1 else {
            return fail("Detail poll interval must be at least 1 second.")
        }

        var updated = settings
        updated.matrix = MatrixConfig(host: host, port: port, timeout: timeout, pollInterval: poll, detailPollInterval: detail)
        updated.appearance = draft.appearance

        do {
            if !draft.adminPassword.isEmpty {
                try secrets.setSecret(draft.adminPassword, for: Self.adminAccount)
            }
            try updated.save()
        } catch {
            return fail("Couldn't save: \(error.localizedDescription)")
        }

        let connectionChanged = updated.matrix != settings.matrix || !draft.adminPassword.isEmpty
        settings = updated
        draft.host = host
        draft.adminPassword = ""
        settingsMessage = ("Saved.", false)
        if connectionChanged { reconfigureStore() }
    }

    func removeAdminPassword() {
        do {
            try secrets.setSecret(nil, for: Self.adminAccount)
        } catch {
            return fail("Couldn't remove the password: \(error.localizedDescription)")
        }
        draft.adminPassword = ""
        settingsMessage = ("Admin password removed.", false)
        reconfigureStore()
    }

    /// Appearance applies immediately; the other fields wait for Save.
    func setAppearance(_ appearance: Appearance) {
        draft.appearance = appearance
        guard settings.appearance != appearance else { return }
        settings.appearance = appearance
        try? settings.save()
    }

    private func reconfigureStore() {
        guard let store else { return }
        let config = settings.matrix
        let password = (try? secrets.secret(for: Self.adminAccount)) ?? nil
        Task { await store.reconfigure(config: config, adminPassword: password) }
    }

    private func fail(_ text: String) {
        settingsMessage = (text, true)
    }
}
