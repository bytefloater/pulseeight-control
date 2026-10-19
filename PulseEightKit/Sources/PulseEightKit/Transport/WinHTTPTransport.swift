#if os(Windows)
import Foundation
import WinSDK

// HTTP over the Windows system stack (winhttp.dll).
//
// swift-corelibs-foundation's URLSession (libcurl driven from libdispatch) crashed the process
// with an access violation in dispatch.dll when many requests ran back to back, so on Windows the
// matrix is reached through WinHTTP instead. The Swift WinSDK module doesn't expose winhttp.h, so
// the few functions needed are looked up at run time. Each request is synchronous and runs on its
// own thread; nothing here touches libdispatch or Swift's cooperative thread pool.

private typealias Handle = UnsafeMutableRawPointer
private typealias Wide = UnsafePointer<UInt16>

private struct WinHTTPAPI {
    let open: @convention(c) (Wide?, UInt32, Wide?, Wide?, UInt32) -> Handle?
    let setTimeouts: @convention(c) (Handle?, Int32, Int32, Int32, Int32) -> Int32
    let connect: @convention(c) (Handle?, Wide?, UInt16, UInt32) -> Handle?
    let openRequest: @convention(c) (Handle?, Wide?, Wide?, Wide?, Wide?, UnsafeRawPointer?, UInt32) -> Handle?
    let sendRequest: @convention(c) (Handle?, Wide?, UInt32, UnsafeRawPointer?, UInt32, UInt32, UInt) -> Int32
    let receiveResponse: @convention(c) (Handle?, UnsafeRawPointer?) -> Int32
    let queryHeaders: @convention(c) (Handle?, UInt32, Wide?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    let readData: @convention(c) (Handle?, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    let closeHandle: @convention(c) (Handle?) -> Int32
    let setOption: @convention(c) (Handle?, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32

    static let shared: WinHTTPAPI? = {
        guard let module = "winhttp.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = GetProcAddress(module, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard
            let open = symbol("WinHttpOpen", as: (@convention(c) (Wide?, UInt32, Wide?, Wide?, UInt32) -> Handle?).self),
            let setTimeouts = symbol("WinHttpSetTimeouts", as: (@convention(c) (Handle?, Int32, Int32, Int32, Int32) -> Int32).self),
            let connect = symbol("WinHttpConnect", as: (@convention(c) (Handle?, Wide?, UInt16, UInt32) -> Handle?).self),
            let openRequest = symbol("WinHttpOpenRequest", as: (@convention(c) (Handle?, Wide?, Wide?, Wide?, Wide?, UnsafeRawPointer?, UInt32) -> Handle?).self),
            let sendRequest = symbol("WinHttpSendRequest", as: (@convention(c) (Handle?, Wide?, UInt32, UnsafeRawPointer?, UInt32, UInt32, UInt) -> Int32).self),
            let receiveResponse = symbol("WinHttpReceiveResponse", as: (@convention(c) (Handle?, UnsafeRawPointer?) -> Int32).self),
            let queryHeaders = symbol("WinHttpQueryHeaders", as: (@convention(c) (Handle?, UInt32, Wide?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32).self),
            let readData = symbol("WinHttpReadData", as: (@convention(c) (Handle?, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32).self),
            let closeHandle = symbol("WinHttpCloseHandle", as: (@convention(c) (Handle?) -> Int32).self),
            let setOption = symbol("WinHttpSetOption", as: (@convention(c) (Handle?, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32).self)
        else { return nil }
        return WinHTTPAPI(
            open: open, setTimeouts: setTimeouts, connect: connect, openRequest: openRequest,
            sendRequest: sendRequest, receiveResponse: receiveResponse, queryHeaders: queryHeaders,
            readData: readData, closeHandle: closeHandle, setOption: setOption)
    }()
}

private func wide(_ string: String) -> [UInt16] { Array(string.utf16) + [0] }

/// Owns the WinHTTP session handle for the lifetime of a transport.
private final class Session: @unchecked Sendable {
    let api: WinHTTPAPI
    let handle: Handle

    init?(api: WinHTTPAPI, timeout: TimeInterval) {
        let agent = wide("PulseEightControl")
        guard let handle = agent.withUnsafeBufferPointer({ api.open($0.baseAddress, 1 /* no proxy */, nil, nil, 0) })
        else { return nil }
        let milliseconds = Int32(max(1, min(timeout, 600)) * 1000)
        _ = api.setTimeouts(handle, milliseconds, milliseconds, milliseconds, milliseconds)
        self.api = api
        self.handle = handle
    }

    deinit { _ = api.closeHandle(handle) }
}

public struct WinHTTPTransport: HTTPTransport {
    private static let timedOut: UInt32 = 12002 // ERROR_WINHTTP_TIMEOUT

    private let session: Session?

    public init(timeout: TimeInterval) {
        session = WinHTTPAPI.shared.flatMap { Session(api: $0, timeout: timeout) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let session else { throw TransportError("WinHTTP isn't available") }
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning: try Self.performWithRetry(request, on: session)) }
                catch { continuation.resume(throwing: error) }
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// The matrix now and then drops a connection before answering. Every request the app sends is
    /// safe to repeat (reads, and commands that set a value), so a dropped connection is retried.
    private static func performWithRetry(_ request: HTTPRequest, on session: Session) throws -> HTTPResponse {
        var attempt = 0
        while true {
            do { return try perform(request, on: session) }
            catch let error as TransportError where error.isConnectionDrop && attempt < 2 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
            }
        }
    }

    private static func fail(_ what: String) -> TransportError {
        let code = GetLastError()
        return TransportError(
            "\(what) (WinHTTP error \(code))", isTimeout: code == timedOut,
            isConnectionDrop: code == 12030 /* ERROR_WINHTTP_CONNECTION_ERROR */)
    }

    private static func perform(_ request: HTTPRequest, on session: Session) throws -> HTTPResponse {
        let api = session.api
        guard let host = request.url.host else { throw TransportError("The address has no host") }
        let secure = request.url.scheme?.lowercased() == "https"
        let port = UInt16(request.url.port ?? (secure ? 443 : 80))

        var target = request.url.path.isEmpty ? "/" : (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? request.url.path)
        if let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery { target += "?" + query }

        let hostName = wide(host)
        guard let connection = hostName.withUnsafeBufferPointer({ api.connect(session.handle, $0.baseAddress, port, 0) })
        else { throw fail("Couldn't connect") }
        defer { _ = api.closeHandle(connection) }

        let verb = wide(request.method.rawValue)
        let path = wide(target)
        let flags: UInt32 = secure ? 0x0080_0000 /* WINHTTP_FLAG_SECURE */ : 0
        guard let handle = verb.withUnsafeBufferPointer({ verbPointer in
            path.withUnsafeBufferPointer { pathPointer in
                api.openRequest(connection, verbPointer.baseAddress, pathPointer.baseAddress, nil, nil, nil, flags)
            }
        }) else { throw fail("Couldn't create the request") }
        defer { _ = api.closeHandle(handle) }

        if !request.followRedirects {
            var policy: UInt32 = 0 // WINHTTP_OPTION_REDIRECT_POLICY_NEVER
            // WINHTTP_OPTION_REDIRECT_POLICY
            guard api.setOption(handle, 88, &policy, UInt32(MemoryLayout<UInt32>.size)) != 0
            else { throw fail("Couldn't turn off redirects") }
        }

        // A fresh connection per request: the matrix closes idle ones, and reusing a closed one fails.
        let headers = wide("Connection: close\r\n" + (request.jsonBody == nil ? "" : "Content-Type: application/json\r\n"))
        let body = request.jsonBody ?? Data()
        let sent: Int32 = headers.withUnsafeBufferPointer { headerPointer in
            body.withUnsafeBytes { bodyPointer in
                api.sendRequest(
                    handle, headerPointer.baseAddress, UInt32(bitPattern: -1), // -1: header text is null-terminated
                    bodyPointer.baseAddress, UInt32(body.count), UInt32(body.count), 0)
            }
        }
        guard sent != 0 else { throw fail("Couldn't send the request") }
        guard api.receiveResponse(handle, nil) != 0 else { throw fail("No response") }

        var status: UInt32 = 0
        var statusSize = UInt32(MemoryLayout<UInt32>.size)
        // WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
        guard api.queryHeaders(handle, 19 | 0x2000_0000, nil, &status, &statusSize, nil) != 0
        else { throw fail("No status code") }

        var location: String?
        if !request.followRedirects {
            // WINHTTP_QUERY_LOCATION; the size is in bytes and includes the terminator, so ask for the size first.
            var size: UInt32 = 0
            _ = api.queryHeaders(handle, 33, nil, nil, &size, nil)
            if size > 2 {
                var text = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
                if text.withUnsafeMutableBytes({ api.queryHeaders(handle, 33, nil, $0.baseAddress, &size, nil) }) != 0 {
                    location = String(decoding: text.prefix { $0 != 0 }, as: UTF16.self)
                }
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var read: UInt32 = 0
            let ok = buffer.withUnsafeMutableBytes { api.readData(handle, $0.baseAddress, UInt32($0.count), &read) }
            guard ok != 0 else { throw fail("The response was cut short") }
            if read == 0 { break }
            data.append(buffer, count: Int(read))
        }
        return HTTPResponse(status: Int(status), body: data, location: location)
    }
}
#endif
