import Foundation
import PulseEightCore
import Observation
import PulseEightKit

enum Page: String, CaseIterable, Identifiable {
    case routing, hardware

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .routing: strings.text(.navRouting)
        case .hardware: strings.text(.navHardware)
        }
    }

    /// SF Symbol for the toolbar and View menu.
    var symbol: String {
        switch self {
        case .routing: "square.grid.3x3"
        case .hardware: "cpu"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case connections, appearance, updates

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .connections: strings.text(.settingsConnections)
        case .appearance: strings.text(.settingsAppearance)
        case .updates: strings.text(.settingsUpdates)
        }
    }

    /// SF Symbol name for the Settings sidebar.
    var symbol: String {
        switch self {
        case .connections: "network"
        case .appearance: "paintbrush"
        case .updates: "arrow.triangle.2.circlepath"
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

/// The matrix popover's fields, kept as strings until Save validates them.
struct MatrixDraft: Equatable {
    /// nil while adding a matrix.
    var id: UUID?
    var name = ""
    var host = ""
    var port = "80"
    var timeout = "10"
    var pollInterval = "5"
    var detailPollInterval = "20"
    /// Blank means "keep what is saved".
    var adminPassword = ""
    /// A password is saved for this matrix (the field itself never shows it).
    var adminPasswordSaved = false
    /// Forget the saved password when saving.
    var clearAdminPassword = false

    init() {}

    init(_ profile: MatrixProfile, adminPasswordSaved: Bool) {
        id = profile.id
        name = profile.name
        host = profile.config.host ?? ""
        port = String(profile.config.port)
        timeout = String(profile.config.timeout)
        pollInterval = String(profile.config.pollInterval)
        detailPollInterval = String(profile.config.detailPollInterval)
        self.adminPasswordSaved = adminPasswordSaved
    }

    var input: MatrixInput {
        MatrixInput(
            id: id, name: name, host: host, port: port, timeout: timeout, pollInterval: pollInterval,
            detailPollInterval: detailPollInterval, adminPassword: adminPassword, clearAdminPassword: clearAdminPassword
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
    /// a routine poll doesn't re-evaluate ~270 tiles.
    var ports: [MatrixPort] = []
    /// Firmware updates available; stored for the same reason as `ports`.
    private(set) var updateCount = 0
    private(set) var settings: AppSettings
    /// Stored (not derived) so views that only need to know "connected or not" don't re-run on
    /// every update.
    private(set) var phase: ConnectionPhase
    private(set) var adminConfigured = false

    /// The matrix popover's fields.
    var matrixDraft = MatrixDraft()
    /// Why the popover's Save (or Find Matrix) didn't work, or what it found.
    var matrixMessage: (text: String, isError: Bool)?
    var page: Page = .routing
    /// The Hardware topic being shown; nil is the list of topics.
    var hardwareTopic: HardwareTopic?
    var settingsPane: SettingsPane = .connections
    var retrying = false
    /// True while gotomymatrix.com is being asked where the matrix is.
    var discovering = false
    /// Why the last "Find Matrix" on the connection screen found nothing.
    var discoveryError: String?
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
    /// Whether macOS lets this app reach the local network; without it nothing can talk to a matrix.
    let localNetwork: LocalNetworkPermission
    /// How long a new connection attempt is given before the screen says the matrix can't be reached. A first
    /// attempt often fails for a moment (macOS is still asking about the local network, the Wi-Fi is just up),
    /// and "Can't reach the matrix" for something that then fixes itself is a false alarm.
    let connectionGrace: Duration
    /// True from the start of an attempt until it has had its `connectionGrace`, or connects.
    private(set) var inGracePeriod = false
    private var graceTask: Task<Void, Never>?

    /// Set to ask "Restart the matrix?" (see `requestRestart`).
    var confirmingRestart = false
    /// Why the last restart didn't start, for an alert.
    var restartError: String?
    /// True from the moment a restart was sent until the matrix has gone away and come back.
    private(set) var isRestarting = false
    private var restartTask: Task<Void, Never>?
    private var restartSawMatrixGo = false
    /// How long to wait for the matrix to be seen going away before deciding the restart didn't happen. The
    /// connection counts as live for up to 15 seconds after the matrix stops answering, so this must be longer.
    let restartWatch: Duration
    /// The longest to show "Restarting" for. A real restart takes about a minute.
    let restartLimit: Duration

    init(
        core: AppCore = AppCore(), localNetwork: LocalNetworkPermission? = nil, connectionGrace: Duration = .seconds(5),
        restartWatch: Duration = .seconds(45), restartLimit: Duration = .seconds(180)
    ) {
        let localNetwork = localNetwork ?? LocalNetworkPermission()
        self.core = core
        self.connectionGrace = connectionGrace
        self.restartWatch = restartWatch
        self.restartLimit = restartLimit
        self.localNetwork = localNetwork
        settings = core.settings
        phase = core.phase
        // Development switches, like P8_CONFIG_DIR: open on a given page or Settings pane (to look at one without
        // clicking to it).
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["P8_START_PAGE"], let start = Page(rawValue: name) { page = start }
        if let name = environment["P8_HARDWARE_TOPIC"], let topic = HardwareTopic(rawValue: name) { hardwareTopic = topic }
        if let name = environment["P8_SETTINGS_PANE"], let pane = SettingsPane(rawValue: name) { settingsPane = pane }
        localNetwork.onGranted = { [weak self] in self?.localNetworkGranted() }
    }

    // MARK: Derived state

    /// What the screen shows: a failure that is still inside its grace period counts as still connecting.
    var displayPhase: ConnectionPhase {
        if isRestarting { return .connecting }
        if inGracePeriod, case .disconnected = phase { return .connecting }
        return phase
    }

    /// The text the window shows, in the language in force. Reading the saved language makes the views that use it redraw when
    /// the language changes.
    var strings: Strings {
        _ = settings.language
        return core.strings
    }

    var connectionSummary: String {
        if isRestarting { return strings.text(.connectionRestarting, core.hostLabel) }
        return displayPhase == phase ? core.connectionSummary : strings.text(.connectionConnecting, core.hostLabel)
    }
    var hostLabel: String { core.hostLabel }

    var matrices: [MatrixProfile] { settings.matrices }
    var selectedMatrixID: UUID? { settings.selectedMatrix?.id }

    /// Short form for the window chrome; the host is in Settings.
    var connectionShort: String {
        if isRestarting { return strings.text(.connectionShortRestarting) }
        return switch displayPhase {
        case .connected: strings.text(.connectionShortConnected)
        case .connecting: strings.text(.connectionConnectingTitle)
        case .notConfigured: strings.text(.connectionNotConfigured)
        case .disconnected: strings.text(.connectionShortDisconnected)
        }
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
        ensureLocalNetworkPermission()
        beginConnectionGrace()
        await core.start()
    }

    private var started = false

    // MARK: Connection grace

    /// Starts the grace period for a new connection attempt (the app starting, a retry, another matrix).
    func beginConnectionGrace() {
        graceTask?.cancel()
        guard connectionGrace > .zero else { return }
        inGracePeriod = true
        graceTask = Task { [connectionGrace] in
            try? await Task.sleep(for: connectionGrace)
            guard !Task.isCancelled else { return }
            inGracePeriod = false
        }
    }

    private func endConnectionGrace() {
        graceTask?.cancel()
        if inGracePeriod { inGracePeriod = false }
    }

    // MARK: Local network permission

    /// Asks macOS for permission to use the local network, if the selected matrix is on it. Done before the first
    /// poll so the question is on screen straight away, not discovered through a failed connection.
    func ensureLocalNetworkPermission() {
        guard let host = core.selectedMatrix?.config.host, !Self.isOnThisMac(host) else { return }
        localNetwork.check()
    }

    /// The answer just turned to yes: connect now rather than at the next poll.
    private func localNetworkGranted() {
        if phase != .connected { retry() }
    }

    nonisolated static func isOnThisMac(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespaces).lowercased()
        return name == "localhost" || name == "::1" || name == "[::1]" || name.hasPrefix("127.")
    }

    /// Each assignment only happens when the value changed: assigning an observable property
    /// notifies its readers even when the value is equal, which would re-run the views on every poll.
    private func apply(_ update: CoreUpdate) {
        if update.state != state { state = update.state }
        let newPorts = update.state?.ports ?? []
        if newPorts != ports { ports = newPorts }
        let count = update.state?.updates.count ?? 0
        if count != updateCount { updateCount = count }
        if update.settings != settings { settings = update.settings }
        if update.phase != phase { phase = update.phase }
        if update.phase == .connected { endConnectionGrace() }
        watchRestart(update)
        if update.adminConfigured != adminConfigured { adminConfigured = update.adminConfigured }
    }

    // MARK: Actions

    /// Poll right now instead of waiting for the next tick. Used by "Retry now" and the Matrix menu.
    func retry() {
        guard !retrying else { return }
        retrying = true
        beginConnectionGrace()
        Task {
            try? await core.retry()
            retrying = false
        }
    }

    /// Drop the connection and start again from the saved settings.
    func reconnect() {
        beginConnectionGrace()
        core.reconnect()
    }

    func route(input: Int, output: Int) {
        let key = RouteKey(input: input, output: output)
        guard !pendingRoutes.contains(key) else { return }
        pendingRoutes.insert(key)
        Task {
            do {
                try await core.route(input: input, output: output)
                // The tick only moves once the matrix itself reports the new route.
                await waitForState { state in
                    state.ports.first { $0.mode == .output && $0.bay == output }?.receiveFrom == input
                }
            } catch {
                // The alert says what failed (routingErrorTitle); this is why.
                routeError = error.localizedDescription
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

    /// The language of the app: a code from `Languages.all`, or `Languages.systemSetting` to follow macOS.
    func setLanguage(_ code: String) {
        try? core.setLanguage(code)
    }

    /// Whether updates may be release candidates and betas (Settings > Updates).
    func setUpdatePrereleases(_ on: Bool) {
        core.setUpdatePrereleases(on)
    }

    func setHighlightGrid(_ on: Bool) {
        core.setHighlightGrid(on)
    }

    func setShowStatusBar(_ on: Bool) {
        core.setShowStatusBar(on)
    }

    func setAppearance(_ appearance: Appearance) {
        core.setAppearance(appearance)
    }

    // MARK: Restart

    /// Starts the restart question (only for an admin: the matrix needs the password). The matrix restarts the moment
    /// it is asked, with no confirmation of its own, so nothing sends the request until `restartMatrix`, which only
    /// the alert's Restart button calls.
    @discardableResult
    func requestRestart() -> Bool {
        guard adminConfigured, !isRestarting else { return false }
        confirmingRestart = true
        return true
    }

    /// Sends the restart. Called once the person has said yes.
    func restartMatrix() {
        confirmingRestart = false
        guard adminConfigured, !isRestarting else { return }
        restartError = nil
        Task {
            do {
                try await core.restartMatrix()
                beginRestartWait()
            } catch {
                restartError = error.localizedDescription
            }
        }
    }

    /// From now until the matrix has gone away and come back, the window says it is restarting instead of
    /// showing an error.
    private func beginRestartWait() {
        isRestarting = true
        restartSawMatrixGo = false
        restartTask?.cancel()
        restartTask = Task { [restartWatch, restartLimit] in
            try? await Task.sleep(for: restartWatch)
            // Never seen going away: it didn't restart after all (or came back before a poll noticed).
            if !Task.isCancelled, !restartSawMatrixGo { endRestart(); return }
            try? await Task.sleep(for: restartLimit)
            if !Task.isCancelled { endRestart() }
        }
    }

    private func endRestart() {
        restartTask?.cancel()
        if isRestarting { isRestarting = false }
    }

    private func watchRestart(_ update: CoreUpdate) {
        guard isRestarting else { return }
        let reachable = update.phase == .connected && update.state?.status.error == nil
        if !reachable {
            restartSawMatrixGo = true
        } else if restartSawMatrixGo {
            endRestart()
        }
    }

    // MARK: Matrices

    /// Fills the popover's fields: from the matrix `id`, or empty to add one.
    func beginEditingMatrix(_ id: UUID?) {
        matrixMessage = nil
        if let id, let profile = settings.matrices.first(where: { $0.id == id }) {
            matrixDraft = MatrixDraft(profile, adminPasswordSaved: core.hasAdminPassword(for: id))
        } else {
            matrixDraft = MatrixDraft()
        }
    }

    /// Validates and saves the popover's fields. True when saved, so the popover can close.
    @discardableResult
    func saveMatrixDraft() -> Bool {
        matrixMessage = nil
        do {
            try core.saveMatrix(matrixDraft.input)
            beginConnectionGrace()
            ensureLocalNetworkPermission()
            return true
        } catch {
            matrixMessage = (error.localizedDescription, true)
            return false
        }
    }

    func removeMatrix(id: UUID) {
        do {
            try core.removeMatrix(id: id)
            resetPerMatrixState()
        } catch {
            matrixMessage = (error.localizedDescription, true)
        }
    }

    /// Shows another matrix.
    func selectMatrix(id: UUID) {
        guard id != core.selectedMatrix?.id else { return }
        do {
            try core.selectMatrix(id: id)
            resetPerMatrixState()
            beginConnectionGrace()
            ensureLocalNetworkPermission()
        } catch {
            matrixMessage = (error.localizedDescription, true)
        }
    }

    /// What was in flight for the matrix just left means nothing to the next one.
    private func resetPerMatrixState() {
        endRestart()
        hardwareTopic = nil
        confirmingRestart = false
        pendingRoutes = []
        selectedPort = nil
        backlightPending = nil
        statusLEDPending = nil
        frontPanelError = nil
        routeError = nil
    }

    /// Asks the discovery service for the matrix on this network. Nil (with the reason reported) if it found none.
    private func discover(reportingTo report: (String) -> Void) async -> DiscoveredMatrix? {
        discovering = true
        defer { discovering = false }
        do {
            if let found = try await core.discoverMatrix() { return found }
            report(strings.text(.matrixNoneFound))
        } catch {
            report(error.localizedDescription)
        }
        return nil
    }

    /// The popover: fills in Host and Port from what was found. Nothing is saved until Save.
    func findMatrixForDraft() async {
        matrixMessage = nil
        guard let found = await discover(reportingTo: { matrixMessage = ($0, true) }) else { return }
        matrixDraft.host = found.host
        matrixDraft.port = String(found.port)
        matrixMessage = (strings.text(.matrixFound, found.host), false)
    }

    /// The no-matrix screen: adds what was found and connects to it straight away.
    func findAndConnect() async {
        discoveryError = nil
        guard let found = await discover(reportingTo: { discoveryError = $0 }) else { return }
        do {
            // One already configured for that address is shown rather than added a second time.
            if let known = settings.matrices.first(where: { $0.config.host == found.host && $0.config.port == found.port }) {
                selectMatrix(id: known.id)
                return
            }
            let id = try core.saveMatrix(MatrixInput(host: found.host, port: String(found.port)))
            try core.selectMatrix(id: id)
            beginConnectionGrace()
            ensureLocalNetworkPermission()
        } catch {
            discoveryError = error.localizedDescription
        }
    }
}
