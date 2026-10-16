import Foundation

/// Read and routing endpoints. Replaces `PulseEightMatrixClient` from pulse_eight_matrix_client.
/// Stateless: caching and polling live in `MatrixStore`.
public struct MatrixClient: Sendable {
    let baseURL: URL
    let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(host: String, port: Int = 80, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let baseURL = URL(string: "http://\(host):\(port)") else {
            throw MatrixError.api("Invalid host '\(host)'")
        }
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
    }

    // MARK: Endpoints

    public func systemDetails() async throws -> SystemDetails {
        try await get("/System/Details")
    }

    public func systemFeatures() async throws -> SystemFeatures {
        try await get("/system/features")
    }

    public func ports() async throws -> [MatrixPort] {
        try await get("/Port/List", as: PortListResponse.self).ports
    }

    public func inputDetails(bay: Int) async throws -> InputPortDetails {
        try await get("/Port/Details/Input/\(bay)")
    }

    public func outputDetails(bay: Int) async throws -> OutputPortDetails {
        try await get("/Port/Details/Output/\(bay)")
    }

    @discardableResult
    public func setPort(input: Int, output: Int) async throws -> SetPortResponse {
        try await get("/Port/Set/\(input)/\(output)")
    }

    /// Case-insensitive lookup, first match wins (same as the Python client).
    @discardableResult
    public func route(inputNamed inputName: String, outputNamed outputName: String) async throws -> SetPortResponse {
        let all = try await ports()
        guard let input = all.first(where: { $0.mode == .input && $0.name.lowercased() == inputName.lowercased() }) else {
            throw MatrixError.portNotFound("Input port '\(inputName)' not found")
        }
        guard let output = all.first(where: { $0.mode == .output && $0.name.lowercased() == outputName.lowercased() }) else {
            throw MatrixError.portNotFound("Output port '\(outputName)' not found")
        }
        return try await setPort(input: input.bay, output: output.bay)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await fetch(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MatrixError.api("Unexpected response from \(path): \(error)")
        }
    }

    private func fetch(_ path: String) async throws -> Data {
        // The device's own web UI appends a millisecond timestamp to defeat caching.
        let stamp = Int(now().timeIntervalSince1970 * 1000)
        let separator = path.contains("?") ? "&" : "?"
        guard let url = URL(string: baseURL.absoluteString + path + "\(separator)_=\(stamp)") else {
            throw MatrixError.api("Invalid path \(path)")
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: .get, url: url))
        } catch let error as TransportError {
            let kind = error.isTimeout ? "TimeoutError" : "ClientError"
            throw MatrixError.connection("\(kind) - Failed to connect to matrix: \(error.description)")
        }

        guard response.status == 200 else {
            throw MatrixError.api("API returned status \(response.status)")
        }
        if let envelope = try? JSONDecoder().decode(ResultEnvelope.self, from: response.body),
           envelope.result == false {
            throw MatrixError.api("API returned Result=false: \(envelope.message ?? "Unknown error")")
        }
        return response.body
    }
}

/// The device wraps every reply in `{"Result": bool, "Message": ...}`.
struct ResultEnvelope: Decodable {
    var result: Bool?
    var message: String?

    enum CodingKeys: String, CodingKey { case result = "Result", message = "Message" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decodeIfPresent(LenientBool.self, forKey: .result)?.wrappedValue
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }
}
