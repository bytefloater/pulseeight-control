import Foundation
import PulseEightKit

public enum ConnectionPhase: Equatable, Sendable {
    case notConfigured
    case connecting
    case connected
    case disconnected(String?)

    /// Stable machine-readable name, used by the JSON interface.
    public var name: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        }
    }
}

/// Raw text from the settings form, validated by `AppCore.saveSettings`.
public struct SettingsInput: Sendable, Equatable {
    public var host: String
    public var port: String
    public var timeout: String
    public var pollInterval: String
    public var detailPollInterval: String
    /// nil or empty keeps the saved password.
    public var adminPassword: String?

    public init(
        host: String, port: String = "80", timeout: String = "10", pollInterval: String = "5",
        detailPollInterval: String = "20", adminPassword: String? = nil
    ) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.detailPollInterval = detailPollInterval
        self.adminPassword = adminPassword
    }
}

/// Raw text from a matrix's form, validated by `AppCore.saveMatrix`.
public struct MatrixInput: Sendable, Equatable {
    /// nil adds a new matrix.
    public var id: UUID?
    /// Blank means the address is shown instead.
    public var name: String
    public var host: String
    public var port: String
    public var timeout: String
    public var pollInterval: String
    public var detailPollInterval: String
    /// nil or empty keeps the saved password.
    public var adminPassword: String?
    /// Forgets the saved password (unless a new one is given).
    public var clearAdminPassword: Bool

    public init(
        id: UUID? = nil, name: String = "", host: String, port: String = "80", timeout: String = "10",
        pollInterval: String = "5", detailPollInterval: String = "20", adminPassword: String? = nil,
        clearAdminPassword: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.detailPollInterval = detailPollInterval
        self.adminPassword = adminPassword
        self.clearAdminPassword = clearAdminPassword
    }
}

public enum CoreError: Error, LocalizedError, Sendable, Equatable {
    /// User input rejected; the message is ready to show.
    case invalid(String)
    case failed(String)
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .failed(let message): return message
        case .notStarted: return "The matrix connection hasn't been started"
        }
    }
}

/// What an observer is told whenever something a UI shows has changed.
public struct CoreUpdate: Sendable, Equatable {
    public var settings: AppSettings
    public var state: MatrixState?
    public var phase: ConnectionPhase
    public var adminConfigured: Bool
}

/// The logic both apps share: settings and secrets, the connection to the matrix, its phase,
/// validation and every command. UI-agnostic and Foundation-only, so it builds on every platform;
/// the macOS app uses it directly and the Windows app reaches it through `PulseEightCoreExports`.
///
/// Thread-safe. Observers are called on an arbitrary thread, never while holding the lock.
public final class AppCore: @unchecked Sendable {
    /// Where the admin password of the matrix `id` lives in the secret store.
    public static func adminAccount(for id: UUID) -> String { "admin-password.\(id.uuidString.lowercased())" }
    /// Where the one matrix's password lived before there could be several.
    static let legacyAdminAccount = "admin-password"

    private let lock = NSLock()
    private let secrets: SecretStore
    private let settingsURL: URL
    private let makeTransport: @Sendable (TimeInterval) -> HTTPTransport
    private let now: @Sendable () -> Date

    private var _settings: AppSettings
    /// Newest state from the store, including per-poll timestamps.
    private var latestState: MatrixState?
    /// The last state observers were told about, with the per-poll timestamps blanked.
    private var publishedKey: MatrixState?
    private var _phase: ConnectionPhase = .notConfigured
    private var store: MatrixStore?
    private var observers: [UUID: @Sendable (CoreUpdate) -> Void] = [:]

    public init(
        secrets: SecretStore = SecretStores.makeDefault(),
        settingsURL: URL = ConfigPaths.settingsFile,
        makeTransport: @escaping @Sendable (TimeInterval) -> HTTPTransport = { makeDefaultTransport(timeout: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secrets = secrets
        self.settingsURL = settingsURL
        self.makeTransport = makeTransport
        self.now = now
        let legacyFile = AppSettings.isLegacyFile(at: settingsURL)
        self._settings = AppSettings.load(from: settingsURL)
        self._phase = computePhase()
        migrateSingleMatrix(rewriteFile: legacyFile)
    }

    /// A file from before there could be several matrices holds one, which is now the first matrix; its
    /// admin password moves to that matrix's own place in the secret store. The file is rewritten in the
    /// current form so the matrix keeps the id its password is filed under.
    private func migrateSingleMatrix(rewriteFile: Bool) {
        var changed = rewriteFile
        if let first = _settings.matrices.first,
           let old = (try? secrets.secret(for: Self.legacyAdminAccount)) ?? nil {
            let account = Self.adminAccount(for: first.id)
            let already = ((try? secrets.secret(for: account)) ?? nil) != nil
            if already || (try? secrets.setSecret(old, for: account)) != nil {
                try? secrets.setSecret(nil, for: Self.legacyAdminAccount)
            }
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Reading state

    public var settings: AppSettings { locked { _settings } }
    public var state: MatrixState? { locked { latestState } }
    public var phase: ConnectionPhase { locked { _phase } }
    public var adminConfigured: Bool { locked { latestState?.adminConfigured ?? false } }

    /// Every matrix that has been added.
    public var matrices: [MatrixProfile] { settings.matrices }
    /// The matrix being shown, if any have been added.
    public var selectedMatrix: MatrixProfile? { settings.selectedMatrix }

    /// Whether an admin password is saved for the matrix `id` (not whether it was accepted).
    public func hasAdminPassword(for id: UUID) -> Bool { adminPassword(for: id) != nil }

    public var update: CoreUpdate { locked { makeUpdate() } }

    /// The language in force: the saved setting, or the operating system's when it is "system".
    public var language: Language { Languages.resolve(settings.language) }

    /// Text for the language in force. Ask again after a change (observers hear about those).
    public var strings: Strings { Strings(language: language) }

    /// "Connected to 192.168.1.150" and friends.
    public var connectionSummary: String {
        switch phase {
        case .connected: strings.text(.connectionConnected, hostLabel)
        case .connecting: strings.text(.connectionConnecting, hostLabel)
        case .notConfigured: strings.text(.connectionNotConfigured)
        case .disconnected: strings.text(.connectionDisconnected, hostLabel)
        }
    }

    /// The selected matrix's name (its address when it has none).
    public var hostLabel: String {
        guard let matrix = selectedMatrix, matrix.config.host?.isEmpty == false else { return strings.text(.connectionNoHost) }
        return matrix.displayName
    }

    /// Selectable EDID profiles for the current matrix (clone entries come from its outputs).
    public func edidProfiles() -> [EdidProfile] {
        let state = self.state
        return EdidProfiles.build(scrambling: state?.system?.features.video.scrambling ?? false, ports: state?.ports ?? [])
    }

    // MARK: Observing

    /// Registers a handler, called after every material change. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping @Sendable (CoreUpdate) -> Void) -> UUID {
        let token = UUID()
        locked { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        locked { observers[token] = nil }
    }

    // MARK: Lifecycle

    /// Connects (if a host is configured) and starts polling. Safe to call more than once.
    public func start() async {
        let alreadyStarted = locked { self.store != nil }
        guard !alreadyStarted else { return }
        let password = adminPassword(for: selectedMatrix?.id)
        let config = settings.matrix
        let store = MatrixStore(
            config: config, adminPassword: password, makeTransport: makeTransport, now: now
        ) { [weak self] state in self?.apply(state) }
        locked { self.store = store }
        await store.start()
    }

    /// Stops polling and drops the connection; `start()` begins again. Releasing the core does the same, so
    /// one that is simply let go of doesn't keep talking to the matrix.
    public func stop() async {
        let store: MatrixStore? = locked {
            let current = self.store
            self.store = nil
            latestState = nil
            publishedKey = nil
            _phase = computePhase()
            return current
        }
        await store?.stop()
    }

    deinit {
        // A MatrixStore keeps itself alive through its polling tasks, so it has to be told to stop.
        if let store { Task { await store.stop() } }
    }

    /// Poll right now instead of waiting for the next tick.
    public func retry() async throws {
        try await requireStore().reconnect()
    }

    /// Drop the connection and start again from the saved settings.
    public func reconnect() {
        reconfigureStore()
    }

    // MARK: Matrix commands

    public func route(input: Int, output: Int) async throws {
        try await perform { try await $0.setPort(input: input, output: output) }
    }

    /// Validates and trims a port name the way the matrix will. Returns the name to send.
    public func validatePortName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CoreError.invalid(strings.text(.errorNameEmpty)) }
        guard name.unicodeScalars.count <= AdminClient.maxNameLength else {
            throw CoreError.invalid(strings.text(.errorNameTooLong, AdminClient.maxNameLength))
        }
        return name
    }

    public func renamePort(mode: PortMode, bay: Int, name: String) async throws {
        let valid = try validatePortName(name)
        try await perform { try await $0.renamePort(mode: mode, bay: bay, name: valid) }
    }

    public func setEdidProfile(bay: Int, profile: Int) async throws {
        try await perform { try await $0.setEdidProfile(bay: bay, profile: profile) }
    }

    /// Restarts the selected matrix. Admin only. The matrix does it the moment it is asked, so the caller has to
    /// have confirmed with the person first; the apps do, and the JSON command refuses without `confirmed`.
    public func restartMatrix() async throws {
        try await perform { try await $0.restart() }
    }

    public func setBacklight(_ level: BacklightLevel) async throws {
        try await perform { try await $0.setBacklight(level) }
    }

    public func setStatusLED(on: Bool) async throws {
        try await perform { try await $0.setStatusLED(on: on) }
    }

    // MARK: Settings

    /// Validates the form and saves the matrix it describes: a new one when `input.id` is nil, otherwise that
    /// one. A first matrix becomes the selected one. Reconnects if the selected matrix's connection changed.
    /// Throws `CoreError.invalid` with a message ready to show; returns the matrix's id.
    @discardableResult
    public func saveMatrix(_ input: MatrixInput) throws -> UUID {
        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw CoreError.invalid(strings.text(.errorHostRequired)) }
        guard let port = Int(input.port), (1...65535).contains(port) else {
            throw CoreError.invalid(strings.text(.errorPortRange))
        }
        guard let timeout = Int(input.timeout), timeout >= 1 else {
            throw CoreError.invalid(strings.text(.errorTimeoutMin))
        }
        guard let poll = Int(input.pollInterval), poll >= 1 else {
            throw CoreError.invalid(strings.text(.errorPollMin))
        }
        guard let detail = Int(input.detailPollInterval), detail >= 1 else {
            throw CoreError.invalid(strings.text(.errorDetailPollMin))
        }

        var updated = settings
        let id = input.id ?? UUID()
        let profile = MatrixProfile(
            id: id, name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
            config: MatrixConfig(host: host, port: port, timeout: timeout, pollInterval: poll, detailPollInterval: detail))
        if let index = updated.matrices.firstIndex(where: { $0.id == id }) {
            updated.matrices[index] = profile
        } else if input.id != nil {
            throw CoreError.invalid(strings.text(.errorMatrixMissing))
        } else {
            updated.matrices.append(profile)
        }
        if updated.selectedMatrix == nil || updated.selectedMatrixID == nil { updated.selectedMatrixID = updated.matrices.first?.id }

        let newPassword = (input.adminPassword ?? "").isEmpty ? nil : input.adminPassword
        let passwordChanged = newPassword != nil || input.clearAdminPassword
        do {
            if passwordChanged { try secrets.setSecret(newPassword, for: Self.adminAccount(for: id)) }
            try updated.save(to: settingsURL)
        } catch {
            throw CoreError.failed(strings.text(.errorSaveFailed, error.localizedDescription))
        }

        let before = settings
        mutateSettings { $0 = updated }
        let wasShown = before.selectedMatrix?.id == updated.selectedMatrix?.id
        let isShown = updated.selectedMatrix?.id == id
        let connectionChanged = !wasShown || (isShown && (before.selectedMatrix?.config != profile.config || passwordChanged))
        if connectionChanged { reconfigureStore() }
        return id
    }

    /// Forgets a matrix and its saved admin password. If it was the selected one, the first remaining matrix is.
    public func removeMatrix(id: UUID) throws {
        var updated = settings
        guard updated.matrices.contains(where: { $0.id == id }) else { throw CoreError.invalid(strings.text(.errorMatrixMissing)) }
        let wasSelected = updated.selectedMatrix?.id == id
        updated.matrices.removeAll { $0.id == id }
        if wasSelected { updated.selectedMatrixID = updated.matrices.first?.id }
        do {
            try secrets.setSecret(nil, for: Self.adminAccount(for: id))
            try updated.save(to: settingsURL)
        } catch {
            throw CoreError.failed(strings.text(.errorSaveFailed, error.localizedDescription))
        }
        mutateSettings(clearingState: wasSelected) { $0 = updated }
        if wasSelected { reconfigureStore() }
    }

    /// Shows another matrix: stops talking to the current one and connects to this one.
    public func selectMatrix(id: UUID) throws {
        var updated = settings
        guard updated.matrices.contains(where: { $0.id == id }) else { throw CoreError.invalid(strings.text(.errorMatrixMissing)) }
        guard updated.selectedMatrix?.id != id else { return }
        updated.selectedMatrixID = id
        do {
            try updated.save(to: settingsURL)
        } catch {
            throw CoreError.failed(strings.text(.errorSaveFailed, error.localizedDescription))
        }
        mutateSettings(clearingState: true) { $0 = updated }
        reconfigureStore()
    }

    /// Saves the form as the selected matrix (adding one if there is none), keeping its name. What the
    /// Windows app calls until it learns about several matrices.
    public func saveSettings(_ input: SettingsInput) throws {
        let current = selectedMatrix
        try saveMatrix(MatrixInput(
            id: current?.id, name: current?.name ?? "", host: input.host, port: input.port, timeout: input.timeout,
            pollInterval: input.pollInterval, detailPollInterval: input.detailPollInterval, adminPassword: input.adminPassword))
    }

    /// Asks Pulse-Eight's discovery service (gotomymatrix.com) which matrix is on this network. nil if it
    /// knows of none. Doesn't change any setting: the caller decides whether to use the answer.
    public func discoverMatrix() async throws -> DiscoveredMatrix? {
        let transport = makeTransport(TimeInterval(settings.matrix.timeout))
        do {
            return try await MatrixDiscovery.find(using: transport)
        } catch {
            throw CoreError.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Forgets the selected matrix's admin password.
    public func removeAdminPassword() throws {
        guard let id = selectedMatrix?.id else { return }
        do {
            try secrets.setSecret(nil, for: Self.adminAccount(for: id))
        } catch {
            throw CoreError.failed(strings.text(.errorRemovePasswordFailed, error.localizedDescription))
        }
        reconfigureStore()
    }

    public func setAppearance(_ appearance: Appearance) {
        mutateSettings { $0.appearance = appearance }
        persist()
    }

    /// `code` is a language code from `Languages.all`, or `Languages.systemSetting`.
    public func setLanguage(_ code: String) throws {
        guard code == Languages.systemSetting || Languages.all.contains(where: { $0.code == code }) else {
            throw CoreError.invalid("Unknown language \"\(code)\"")
        }
        mutateSettings { $0.language = code }
        persist()
    }

    public func setHighlightGrid(_ on: Bool) {
        mutateSettings { $0.highlightGrid = on }
        persist()
    }

    public func setShowStatusBar(_ on: Bool) {
        mutateSettings { $0.showStatusBar = on }
        persist()
    }

    public func setCheckForUpdates(_ on: Bool) {
        mutateSettings { $0.checkForUpdates = on }
        persist()
    }

    // MARK: Internals

    private func persist() {
        try? settings.save(to: settingsURL)
    }

    private func requireStore() throws -> MatrixStore {
        guard let store = locked({ self.store }) else { throw CoreError.notStarted }
        return store
    }

    private func perform(_ work: (MatrixStore) async throws -> Void) async throws {
        try await work(requireStore())
    }

    private func reconfigureStore() {
        guard let store = locked({ self.store }) else { return }
        let config = settings.matrix
        let password = adminPassword(for: selectedMatrix?.id)
        Task { await store.reconfigure(config: config, adminPassword: password) }
    }

    private func adminPassword(for id: UUID?) -> String? {
        guard let id, let password = (try? secrets.secret(for: Self.adminAccount(for: id))) ?? nil, !password.isEmpty
        else { return nil }
        return password
    }

    /// `clearingState` also forgets what the previous matrix reported, so nothing of it is shown while the
    /// next one connects.
    private func mutateSettings(clearingState: Bool = false, _ change: (inout AppSettings) -> Void) {
        let update: CoreUpdate = locked {
            change(&_settings)
            if clearingState {
                latestState = nil
                publishedKey = nil
            }
            _phase = computePhase()
            return makeUpdate()
        }
        notify(update)
    }

    /// Quiet polls (nothing but timestamps changed) notify nobody: UIs can then re-render only on
    /// real changes, which avoids needless view updates on every poll.
    private func apply(_ newState: MatrixState) {
        var key = newState
        key.status.lastPollTime = nil
        key.status.cacheAge = nil
        let update: CoreUpdate? = locked {
            latestState = newState
            let phase = computePhase()
            let changed = key != publishedKey || phase != _phase
            _phase = phase
            guard changed else { return nil }
            publishedKey = key
            return makeUpdate()
        }
        if let update { notify(update) }
    }

    private func notify(_ update: CoreUpdate) {
        let handlers = locked { Array(observers.values) }
        for handler in handlers { handler(update) }
    }

    /// Caller holds the lock.
    private func makeUpdate() -> CoreUpdate {
        CoreUpdate(
            settings: _settings, state: latestState, phase: _phase,
            adminConfigured: latestState?.adminConfigured ?? false
        )
    }

    /// Caller holds the lock (or is still initialising).
    private func computePhase() -> ConnectionPhase {
        guard let status = latestState?.status else {
            return _settings.matrix.host?.isEmpty == false ? .connecting : .notConfigured
        }
        if !status.configured { return .notConfigured }
        if status.connected { return .connected }
        if status.lastPollTime == nil && status.error == nil { return .connecting }
        return .disconnected(status.error)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
