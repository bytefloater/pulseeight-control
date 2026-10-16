import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: URL
    public var jsonBody: Data?

    public init(method: Method, url: URL, jsonBody: Data? = nil) {
        self.method = method
        self.url = url
        self.jsonBody = jsonBody
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Seam between the device clients and the network, so tests (and, if URLSession
/// proves unreliable on Windows, an alternative stack) can slot in.
public protocol HTTPTransport: Sendable {
    /// Throws `TransportError` for anything that never produced an HTTP response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct TransportError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public var isTimeout: Bool
    /// The connection was dropped before a response arrived (worth retrying).
    public var isConnectionDrop: Bool

    public init(_ description: String, isTimeout: Bool = false, isConnectionDrop: Bool = false) {
        self.description = description
        self.isTimeout = isTimeout
        self.isConnectionDrop = isConnectionDrop
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        if let body = request.jsonBody {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Continuation-based rather than `session.data(for:)`: the async overload is newer on
        // swift-corelibs-foundation (Linux/Windows) and this works on every toolchain.
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    let isTimeout = (error as? URLError)?.code == .timedOut
                    continuation.resume(throwing: TransportError(error.localizedDescription, isTimeout: isTimeout))
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: HTTPResponse(status: http.statusCode, body: data ?? Data()))
                } else {
                    continuation.resume(throwing: TransportError("Non-HTTP response"))
                }
            }.resume()
        }
    }
}

/// The transport the apps use: WinHTTP on Windows (URLSession proved unstable there), URLSession elsewhere.
public func makeDefaultTransport(timeout: TimeInterval) -> HTTPTransport {
    #if os(Windows)
    WinHTTPTransport(timeout: timeout)
    #else
    URLSessionTransport(timeout: timeout)
    #endif
}
