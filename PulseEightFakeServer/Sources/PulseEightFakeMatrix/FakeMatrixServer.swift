import Foundation

/// A minimal HTTP/1.1 server around a `FakeMatrix`: one Foundation thread per connection, one request
/// per connection (`Connection: close`). Enough for the clients in PulseEightKit; not a general server.
public final class FakeMatrixServer: @unchecked Sendable {
    public let matrix: FakeMatrix
    public let host: String
    private let requestedPort: UInt16
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var listener: Sockets.Handle?
    private var boundPort: UInt16 = 0
    private var stopping = false
    private var acceptorFinished = DispatchSemaphore(value: 0)

    /// - Parameter port: 0 picks a free port (read it back from `port` after `start()`).
    /// - Parameter log: called with one line per request; nil is silent.
    public init(matrix: FakeMatrix, host: String = "127.0.0.1", port: UInt16 = 8080, log: (@Sendable (String) -> Void)? = nil) {
        self.matrix = matrix
        self.host = host
        self.requestedPort = port
        self.log = log
    }

    /// The port being served (valid once started).
    public var port: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }

    /// Binds the port and starts serving on background threads.
    public func start() throws {
        let handle = try Sockets.makeListener(host: host, port: requestedPort)
        let finished = DispatchSemaphore(value: 0)
        lock.lock()
        listener = handle
        boundPort = Sockets.port(of: handle)
        stopping = false
        acceptorFinished = finished
        lock.unlock()

        let thread = Thread { [self] in
            acceptLoop(handle)
            finished.signal()
        }
        thread.name = "FakeMatrixServer.accept"
        thread.start()
    }

    /// Stops accepting and returns once the port is free; requests already being served finish.
    ///
    /// The accept thread owns the listening socket and is the only one that closes it. Closing it from
    /// here, while that thread is (or is about to be) inside `accept`, let the descriptor number be reused
    /// by the next server's listener, and the dead server's thread then answered that server's clients.
    public func stop() {
        lock.lock()
        guard listener != nil else {
            lock.unlock()
            return
        }
        listener = nil
        stopping = true
        let port = boundPort
        let finished = acceptorFinished
        lock.unlock()

        // Wake the thread out of `accept`; it sees the flag, closes the listener and exits.
        Sockets.connectOnce(host: host == "0.0.0.0" ? "127.0.0.1" : host, port: port)
        _ = finished.wait(timeout: .now() + 5)
    }

    deinit { stop() }

    // MARK: Serving

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop(_ handle: Sockets.Handle) {
        // Sole owner of the listener: it is closed here, after the last `accept`, never from `stop()`.
        defer { Sockets.closeHandle(handle) }
        while !isStopping {
            let client = Sockets.acceptClient(handle)
            if isStopping {
                if client != Sockets.invalid { Sockets.closeHandle(client) } // the wake-up connection
                return
            }
            if client == Sockets.invalid {
                Thread.sleep(forTimeInterval: 0.01) // transient failure (e.g. out of descriptors): keep serving
                continue
            }
            let thread = Thread { [self] in
                serve(client)
                Sockets.closeHandle(client)
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    private func serve(_ client: Sockets.Handle) {
        guard let request = readRequest(client) else { return }
        // Restarting: say nothing, as a matrix that is starting up would (the caller closes the connection).
        if matrix.isOffline { return }
        if matrix.options.latency > 0 { Thread.sleep(forTimeInterval: matrix.options.latency) }

        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        let response = matrix.handle(method: request.method, path: path, body: request.body)
        log?("\(request.method) \(request.target) -> \(response?.status ?? 404)")

        let status = response?.status ?? 404
        let body = response?.body ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
        if response != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        Sockets.sendAll(client, Data(head.utf8) + body)
    }

    private struct Request {
        var method: String
        var target: String
        var body: Data
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let maxRequestBytes = 1 << 20

    /// Reads the request line, headers and (by Content-Length) the body.
    private func readRequest(_ client: Sockets.Handle) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerRange = data.range(of: Self.headerEnd)

        while headerRange == nil {
            let count = buffer.withUnsafeMutableBytes { Sockets.receive(client, into: $0) }
            if count <= 0 || data.count > Self.maxRequestBytes { return nil }
            data.append(buffer, count: count)
            headerRange = data.range(of: Self.headerEnd)
        }
        guard let headerRange else { return nil }

        let head = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let startLine = (lines.first ?? "").split(separator: " ")
        guard startLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength <= Self.maxRequestBytes else { return nil }

        var body = Data(data[headerRange.upperBound...])
        while body.count < contentLength {
            let count = buffer.withUnsafeMutableBytes { Sockets.receive(client, into: $0) }
            if count <= 0 { return nil }
            body.append(buffer, count: count)
        }
        return Request(method: String(startLine[0]).uppercased(), target: String(startLine[1]), body: body.prefix(contentLength))
    }
}
