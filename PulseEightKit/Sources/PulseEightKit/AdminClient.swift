import Foundation

/// Admin-gated endpoints the vendor library doesn't cover. Ported from legacy/PulseEightWeb/backend/app/pulse8_admin.py,
/// which found them by inspecting the matrix's own admin web UI.
///
/// The device issues no session cookie on login, so there is nothing to persist: every
/// action repeats the same login + action round trip.
public struct AdminClient: Sendable {
    /// Matches maxlength on the device's own rename field.
    public static let maxNameLength = 13

    let baseURL: URL
    let transport: HTTPTransport

    public init(host: String, port: Int = 80, transport: HTTPTransport) throws {
        guard let baseURL = URL(string: "http://\(host):\(port)") else {
            throw MatrixError.admin("Invalid host '\(host)'")
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    public func renamePort(mode: PortMode, bay: Int, name: String, password: String) async throws {
        // Python's len() counts code points, not grapheme clusters.
        guard name.unicodeScalars.count <= Self.maxNameLength else {
            throw MatrixError.admin("Name must be \(Self.maxNameLength) characters or fewer")
        }
        try await login(password)
        try await post("/Port/SetName/\(mode.rawValue)/\(bay)/", body: ["Name": name])
    }

    public func setEdidProfile(bay: Int, profile: Int, password: String) async throws {
        try await login(password)
        try await get("/Port/EDID/Set/\(profile)/\(bay)")
    }

    public func setBacklight(_ level: BacklightLevel, password: String) async throws {
        try await login(password)
        try await post("/System/BacklightLED/\(level.rawValue)", body: [:])
    }

    public func setStatusLED(on: Bool, password: String) async throws {
        try await login(password)
        try await post("/System/StatusLED/\(on ? "On" : "Off")", body: [:])
    }

    /// Restarts the matrix. The device does this the moment it is asked, with no confirmation of its own, so
    /// callers must have asked the person first. The device may cut the connection as it goes down, so a dropped
    /// connection after a successful login counts as the restart having begun. Never sent twice.
    public func restart(password: String) async throws {
        try await login(password)
        do {
            _ = try await send(HTTPRequest(method: .get, url: url("/System/Restart"), retryOnDrop: false), path: "/System/Restart")
        } catch MatrixError.admin(let message) where message.hasPrefix(Self.unreachablePrefix) && message.contains(Self.droppedMarker) {
            return
        }
    }

    // MARK: Plumbing

    private static let unreachablePrefix = "Failed to reach matrix"
    private static let droppedMarker = "connection dropped:"

    private func login(_ password: String) async throws {
        try await post("/Account/Login", body: ["Password": password])
    }

    @discardableResult
    private func post(_ path: String, body: [String: String]) async throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: body)
        return try await send(HTTPRequest(method: .post, url: url(path), jsonBody: json), path: path)
    }

    @discardableResult
    private func get(_ path: String) async throws -> Data {
        try await send(HTTPRequest(method: .get, url: url(path)), path: path)
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw MatrixError.admin("Invalid path \(path)")
        }
        return url
    }

    private func send(_ request: HTTPRequest, path: String) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as TransportError {
            // A dropped connection is called one in the text so `restart` can tell it from a refusal or a timeout.
            let kind = error.isConnectionDrop ? "\(Self.droppedMarker) " : ""
            throw MatrixError.admin("\(Self.unreachablePrefix): \(kind)\(error.description)")
        }
        guard response.status == 200 else {
            throw MatrixError.admin("\(path) returned HTTP \(response.status)")
        }
        // Python: `if not data.get("Result", False)` - a missing Result counts as failure here.
        let envelope = try? JSONDecoder().decode(ResultEnvelope.self, from: response.body)
        guard envelope?.result == true else {
            let message = envelope?.message.flatMap { $0.isEmpty ? nil : $0 }
            throw MatrixError.admin(message ?? "\(path) failed")
        }
        return response.body
    }
}
