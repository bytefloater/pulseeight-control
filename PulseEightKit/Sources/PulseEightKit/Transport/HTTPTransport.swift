import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: URL
    public var jsonBody: Data?
    /// False to hand a 3xx back as the response (with `HTTPResponse.location`) instead of following it.
    public var followRedirects: Bool
    /// False for a request that must not be sent twice, such as one that restarts the matrix: the transport then
    /// reports a dropped connection instead of quietly trying again.
    public var retryOnDrop: Bool

    public init(method: Method, url: URL, jsonBody: Data? = nil, followRedirects: Bool = true, retryOnDrop: Bool = true) {
        self.method = method
        self.url = url
        self.jsonBody = jsonBody
        self.followRedirects = followRedirects
        self.retryOnDrop = retryOnDrop
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    /// The `Location` header, as sent. Only read for responses to requests that don't follow redirects.
    public var location: String?

    public init(status: Int, body: Data, location: String? = nil) {
        self.status = status
        self.body = body
        self.location = location
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
    /// macOS refused the connection because the app has no Local Network permission.
    public var isLocalNetworkBlocked: Bool

    /// What the app says when macOS blocks it from the local network; the UI looks for this to offer the
    /// settings button.
    public static let localNetworkBlockedPhrase = "Local Network"

    public init(_ description: String, isTimeout: Bool = false, isConnectionDrop: Bool = false, isLocalNetworkBlocked: Bool = false) {
        self.description = description
        self.isTimeout = isTimeout
        self.isConnectionDrop = isConnectionDrop
        self.isLocalNetworkBlocked = isLocalNetworkBlocked
    }
}

/// Answers every redirect with "don't follow", so the 3xx itself comes back to the caller.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let noRedirectSession: URLSession

    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        // A second session rather than a per-task delegate: corelibs Foundation's support for those is patchy.
        noRedirectSession = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    /// The matrix now and then drops a connection before answering, and its idle ones go away, which a reused
    /// connection then trips over. Every request the app sends is safe to repeat, so a drop is retried (on a
    /// fresh connection, see `sendOnce`). The Windows transport does the same.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request)
            } catch let error as TransportError where error.isConnectionDrop && request.retryOnDrop && attempt < 2 {
                attempt += 1
                Diagnostics.note("Connection dropped on \(request.url.path), retrying (\(attempt)): \(error.description)")
                try? await Task.sleep(nanoseconds: UInt64(50_000_000 * attempt))
            }
        }
    }

    /// True when the error (or one it wraps) says the network path was refused for want of Local Network
    /// permission. Foundation gives no API for this: the only trace is the path description in the error's
    /// user info, which reads "unsatisfied (Local network prohibited)".
    static func isLocalNetworkBlocked(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let error = current {
            if let path = error.userInfo["_NSURLErrorNWPathKey"], "\(path)".contains("Local network prohibited") { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func sendOnce(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        // A new connection each time: the matrix closes idle ones, and reusing a closed one fails.
        urlRequest.setValue("close", forHTTPHeaderField: "Connection")
        urlRequest.httpMethod = request.method.rawValue
        if let body = request.jsonBody {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Continuation-based rather than `session.data(for:)`: the async overload is newer on
        // swift-corelibs-foundation (Linux/Windows) and this works on every toolchain.
        return try await withCheckedThrowingContinuation { continuation in
            (request.followRedirects ? session : noRedirectSession).dataTask(with: urlRequest) { data, response, error in
                if let error {
                    let code = (error as? URLError)?.code
                    if Self.isLocalNetworkBlocked(error as NSError) {
                        // macOS reports this as "The Internet connection appears to be offline", which sends
                        // people to their Wi-Fi when the fix is a switch in Privacy & Security.
                        continuation.resume(throwing: TransportError(
                            "macOS is blocking PulseEight Control from the \(TransportError.localNetworkBlockedPhrase). "
                                + "Allow it in System Settings > Privacy & Security > \(TransportError.localNetworkBlockedPhrase) "
                                + "(NSURLErrorDomain \((error as NSError).code))",
                            isLocalNetworkBlocked: true))
                        return
                    }
                    // The code is in the text because "The network connection was lost" and "Could not connect"
                    // can have several causes, and which one it was is the first thing to know.
                    let detail = "\(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))"
                    continuation.resume(throwing: TransportError(
                        detail, isTimeout: code == .timedOut, isConnectionDrop: code == .networkConnectionLost))
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: HTTPResponse(
                        status: http.statusCode, body: data ?? Data(),
                        location: http.value(forHTTPHeaderField: "Location")))
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
