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
    public static let adminAccount = "admin-password"

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
        self._settings = AppSettings.load(from: settingsURL)
        self._phase = computePhase()
    }

    // MARK: Reading state

    public var settings: AppSettings { locked { _settings } }
    public var state: MatrixState? { locked { latestState } }
    public var phase: ConnectionPhase { locked { _phase } }
    public var adminConfigured: Bool { locked { latestState?.adminConfigured ?? false } }

    public var update: CoreUpdate { locked { makeUpdate() } }

    /// "Connected to 192.168.1.150" and friends.
    public var connectionSummary: String {
        switch phase {
        case .connected: "Connected to \(hostLabel)"
        case .connecting: "Connecting to \(hostLabel)…"
        case .notConfigured: "Not configured"
        case .disconnected: "Not connected to \(hostLabel)"
        }
    }

    /// Host, plus the port when it isn't 80.
    public var hostLabel: String {
        let config = settings.matrix
        guard let host = config.host, !host.isEmpty else { return "no host" }
        return config.port == 80 ? host : "\(host):\(config.port)"
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
        let alreadyStarted = locked { store != nil }
        guard !alreadyStarted else { return }
        let password = (try? secrets.secret(for: Self.adminAccount)) ?? nil
        let config = settings.matrix
        let store = MatrixStore(
            config: config, adminPassword: password, makeTransport: makeTransport, now: now
        ) { [weak self] state in self?.apply(state) }
        locked { self.store = store }
        await store.start()
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
        guard !name.isEmpty else { throw CoreError.invalid("Name can't be empty.") }
        guard name.unicodeScalars.count <= AdminClient.maxNameLength else {
            throw CoreError.invalid("Name must be \(AdminClient.maxNameLength) characters or fewer.")
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

    public func setBacklight(_ level: BacklightLevel) async throws {
        try await perform { try await $0.setBacklight(level) }
    }

    public func setStatusLED(on: Bool) async throws {
        try await perform { try await $0.setStatusLED(on: on) }
    }

    // MARK: Settings

    /// Validates the form, saves settings and the admin password, and reconnects if the
    /// connection changed. Throws `CoreError.invalid` with a message ready to show.
    public func saveSettings(_ input: SettingsInput) throws {
        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw CoreError.invalid("Enter the matrix's IP address or hostname.") }
        guard let port = Int(input.port), (1...65535).contains(port) else {
            throw CoreError.invalid("Port must be a number from 1 to 65535.")
        }
        guard let timeout = Int(input.timeout), timeout >= 1 else {
            throw CoreError.invalid("Timeout must be at least 1 second.")
        }
        guard let poll = Int(input.pollInterval), poll >= 1 else {
            throw CoreError.invalid("Poll interval must be at least 1 second.")
        }
        guard let detail = Int(input.detailPollInterval), detail >= 1 else {
            throw CoreError.invalid("Detail poll interval must be at least 1 second.")
        }

        var updated = settings
        updated.matrix = MatrixConfig(host: host, port: port, timeout: timeout, pollInterval: poll, detailPollInterval: detail)
        let passwordChanged = !(input.adminPassword ?? "").isEmpty

        do {
            if passwordChanged, let password = input.adminPassword {
                try secrets.setSecret(password, for: Self.adminAccount)
            }
            try updated.save(to: settingsURL)
        } catch {
            throw CoreError.failed("Couldn't save: \(error.localizedDescription)")
        }

        let connectionChanged = updated.matrix != settings.matrix || passwordChanged
        mutateSettings { $0 = updated }
        if connectionChanged { reconfigureStore() }
    }

    public func removeAdminPassword() throws {
        do {
            try secrets.setSecret(nil, for: Self.adminAccount)
        } catch {
            throw CoreError.failed("Couldn't remove the password: \(error.localizedDescription)")
        }
        reconfigureStore()
    }

    public func setAppearance(_ appearance: Appearance) {
        mutateSettings { $0.appearance = appearance }
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
        let password = (try? secrets.secret(for: Self.adminAccount)) ?? nil
        Task { await store.reconfigure(config: config, adminPassword: password) }
    }

    private func mutateSettings(_ change: (inout AppSettings) -> Void) {
        let update: CoreUpdate = locked {
            change(&_settings)
            _phase = computePhase()
            return makeUpdate()
        }
        notify(update)
    }

    /// Quiet polls (nothing but timestamps changed) notify nobody: UIs can then re-render only on
    /// real changes, which matters a lot for SwiftCrossUI where a changed value ripples up the tree.
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
