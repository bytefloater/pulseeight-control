import Foundation

/// Connection settings. Keys match backend/config.json so an existing file can be imported as-is.
/// The admin password is deliberately not part of this: it belongs in the OS secret store.
public struct MatrixConfig: Codable, Sendable, Equatable {
    public var host: String?
    public var port: Int
    public var timeout: Int
    public var pollInterval: Int
    public var detailPollInterval: Int

    public init(host: String? = nil, port: Int = 80, timeout: Int = 10, pollInterval: Int = 5, detailPollInterval: Int = 20) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.detailPollInterval = detailPollInterval
    }

    enum CodingKeys: String, CodingKey {
        case host, port, timeout
        case pollInterval = "poll_interval"
        case detailPollInterval = "detail_poll_interval"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MatrixConfig()
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? defaults.timeout
        pollInterval = try c.decodeIfPresent(Int.self, forKey: .pollInterval) ?? defaults.pollInterval
        detailPollInterval = try c.decodeIfPresent(Int.self, forKey: .detailPollInterval) ?? defaults.detailPollInterval
    }
}

public struct ConnectionStatus: Sendable, Equatable {
    public var configured: Bool
    public var connected: Bool
    public var host: String?
    public var port: Int
    public var error: String?
    public var lastPollTime: Date?
    public var cacheAge: TimeInterval?
}

/// Everything the UI renders. A fresh value is published after every change.
public struct MatrixState: Sendable, Equatable {
    public var ports: [MatrixPort] = []
    public var inputDetails: [Int: InputPortDetails] = [:]
    public var outputDetails: [Int: OutputPortDetails] = [:]
    public var system: SystemInfo?
    public var updates: [FirmwareUpdate] = []
    public var status: ConnectionStatus
    /// True when an admin password is set, i.e. rename/EDID/front-panel controls can work.
    public var adminConfigured: Bool

    public var inputs: [MatrixPort] { ports.filter { $0.mode == .input }.sorted { $0.bay < $1.bay } }
    public var outputs: [MatrixPort] { ports.filter { $0.mode == .output }.sorted { $0.bay < $1.bay } }
}

/// Owns the connection to the matrix and keeps cached state fresh. Port of
/// backend/app/pulse8_service.py plus the polling half of CachingPulseEightMatrixClient:
/// routing every `pollInterval`, per-port details every `detailPollInterval`, and system
/// info every 60s. Replaces the WebSocket fan-out with a single `onChange` callback.
public actor MatrixStore {
    /// System info changes far less often than routing state.
    static let systemPollInterval: TimeInterval = 60

    public typealias Handler = @Sendable (MatrixState) -> Void

    private var config: MatrixConfig
    private var adminPassword: String?
    private let makeTransport: @Sendable (TimeInterval) -> HTTPTransport
    private let now: @Sendable () -> Date
    private let onChange: Handler

    private var client: MatrixClient?
    private var admin: AdminClient?

    private var ports: [MatrixPort] = []
    private var inputDetails: [Int: InputPortDetails] = [:]
    private var outputDetails: [Int: OutputPortDetails] = [:]
    private var system: SystemInfo?
    private var lastError: String?
    private var lastPollTime: Date?

    private var routingTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?

    public init(
        config: MatrixConfig,
        adminPassword: String? = nil,
        makeTransport: @escaping @Sendable (TimeInterval) -> HTTPTransport = { URLSessionTransport(timeout: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping Handler
    ) {
        self.config = config
        self.adminPassword = adminPassword
        self.makeTransport = makeTransport
        self.now = now
        self.onChange = onChange
    }

    // MARK: Lifecycle

    public func start() {
        stopTasks()
        guard let host = config.host, !host.isEmpty else {
            publish()
            return
        }
        let transport = makeTransport(TimeInterval(config.timeout))
        do {
            client = try MatrixClient(host: host, port: config.port, transport: transport, now: now)
            admin = try AdminClient(host: host, port: config.port, transport: transport)
        } catch {
            lastError = error.localizedDescription
            publish()
            return
        }
        publish()
        routingTask = Task { [weak self] in await self?.routingLoop() }
        detailsTask = Task { [weak self] in await self?.detailsLoop() }
    }

    public func stop() {
        stopTasks()
        client = nil
        admin = nil
        ports = []
        inputDetails = [:]
        outputDetails = [:]
        system = nil
        lastPollTime = nil
        lastError = nil
    }

    /// Apply new settings without restarting the app.
    public func reconfigure(config: MatrixConfig, adminPassword: String?) {
        stop()
        self.config = config
        self.adminPassword = adminPassword
        start()
    }

    private func stopTasks() {
        routingTask?.cancel()
        detailsTask?.cancel()
        routingTask = nil
        detailsTask = nil
    }

    // MARK: State

    public var state: MatrixState {
        MatrixState(
            ports: ports,
            inputDetails: inputDetails,
            outputDetails: outputDetails,
            system: system,
            updates: updatesAvailable(),
            status: status(),
            adminConfigured: !(adminPassword ?? "").isEmpty
        )
    }

    private func publish() {
        onChange(state)
    }

    /// Stale after max(3 polls, 15s) with no successful port poll.
    private func isConnected() -> Bool {
        guard client != nil, let lastPollTime else { return false }
        return now().timeIntervalSince(lastPollTime) < Double(max(config.pollInterval * 3, 15))
    }

    private func status() -> ConnectionStatus {
        ConnectionStatus(
            configured: !(config.host ?? "").isEmpty,
            connected: isConnected(),
            host: config.host,
            port: config.port,
            error: lastError,
            lastPollTime: lastPollTime,
            cacheAge: lastPollTime.map { now().timeIntervalSince($0) }
        )
    }

    private func updatesAvailable() -> [FirmwareUpdate] {
        outputDetails.sorted { $0.key < $1.key }.compactMap { bay, details in
            details.firmwareVersionAvailable == true
                ? FirmwareUpdate(bay: bay, name: details.base.name, firmwareVersion: details.firmwareVersion)
                : nil
        }
    }

    public func edidProfiles() -> [EdidProfile] {
        EdidProfiles.build(scrambling: system?.features.video.scrambling ?? false, ports: ports)
    }

    // MARK: Actions

    /// Force an immediate retry instead of waiting for the next poll tick.
    public func reconnect() async throws {
        _ = try requireClient()
        await pollPorts()
        publish()
    }

    @discardableResult
    public func setPort(input: Int, output: Int) async throws -> SetPortResponse {
        let result = try await requireClient().setPort(input: input, output: output)
        await afterWrite()
        return result
    }

    @discardableResult
    public func route(inputNamed input: String, outputNamed output: String) async throws -> SetPortResponse {
        let result = try await requireClient().route(inputNamed: input, outputNamed: output)
        await afterWrite()
        return result
    }

    public func renamePort(mode: PortMode, bay: Int, name: String) async throws {
        let (admin, password) = try requireAdmin()
        try await admin.renamePort(mode: mode, bay: bay, name: name, password: password)
        await afterWrite()
    }

    public func setEdidProfile(bay: Int, profile: Int) async throws {
        let (admin, password) = try requireAdmin()
        try await admin.setEdidProfile(bay: bay, profile: profile, password: password)
        spawn { await $0.refreshDetails() }
    }

    public func setBacklight(_ level: BacklightLevel) async throws {
        let (admin, password) = try requireAdmin()
        try await admin.setBacklight(level, password: password)
        spawn { await $0.refreshSystem() }
    }

    public func setStatusLED(on: Bool) async throws {
        let (admin, password) = try requireAdmin()
        try await admin.setStatusLED(on: on, password: password)
        spawn { await $0.refreshSystem() }
    }

    private func requireClient() throws -> MatrixClient {
        guard let client else { throw MatrixError.notConfigured }
        return client
    }

    private func requireAdmin() throws -> (AdminClient, String) {
        guard let admin else { throw MatrixError.notConfigured }
        guard let password = adminPassword, !password.isEmpty else {
            throw MatrixError.admin("Admin password is not set")
        }
        return (admin, password)
    }

    private func afterWrite() async {
        await pollPorts()
        publish()
        spawn { await $0.refreshDetails() }
    }

    private func spawn(_ work: @escaping @Sendable (MatrixStore) async -> Void) {
        Task { [weak self] in
            guard let self else { return }
            await work(self)
        }
    }

    // MARK: Polling

    private func routingLoop() async {
        while !Task.isCancelled {
            await pollPorts()
            publish()
            guard await sleep(seconds: config.pollInterval) else { return }
        }
    }

    private func detailsLoop() async {
        var lastSystemFetch: Date?
        while !Task.isCancelled {
            if lastSystemFetch.map({ now().timeIntervalSince($0) >= Self.systemPollInterval }) ?? true {
                await refreshSystem()
                lastSystemFetch = now()
            }
            await refreshDetails()
            guard await sleep(seconds: config.detailPollInterval) else { return }
        }
    }

    /// Returns false if cancelled.
    private func sleep(seconds: Int) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Swallows errors into `lastError`; connection state is derived from `lastPollTime`.
    private func pollPorts() async {
        guard let client else { return }
        do {
            ports = try await client.ports()
            lastPollTime = now()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSystem() async {
        guard let client else { return }
        do {
            let details = try await client.systemDetails()
            let features = try await client.systemFeatures()
            system = SystemInfo(details: details, features: features)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        publish()
    }

    func refreshDetails() async {
        guard let client else { return }
        await pollPorts()
        guard lastError == nil else {
            publish()
            return
        }

        for port in ports {
            do {
                switch port.mode {
                case .input: inputDetails[port.bay] = try await client.inputDetails(bay: port.bay)
                case .output: outputDetails[port.bay] = try await client.outputDetails(bay: port.bay)
                }
            } catch {
                // One flaky port shouldn't blank the others; keep its previous details.
            }
        }

        // Front panel backlight can change at any time (physical button, the matrix's own admin
        // UI), so it rides this faster cadence rather than the 60s system refresh.
        if let details = system?.details, let features = try? await client.systemFeatures() {
            system = SystemInfo(details: details, features: features)
        }
        publish()
    }
}
