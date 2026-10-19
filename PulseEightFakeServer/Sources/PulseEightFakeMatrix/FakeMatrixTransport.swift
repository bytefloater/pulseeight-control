import Foundation
import PulseEightKit

/// Talks to a `FakeMatrix` directly, with no sockets, so tests can run the real clients, store and
/// core against it in-process.
public struct FakeMatrixTransport: HTTPTransport {
    private let matrix: FakeMatrix

    public init(_ matrix: FakeMatrix) {
        self.matrix = matrix
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if matrix.isOffline { throw TransportError("The matrix is restarting", isConnectionDrop: true) }
        if matrix.options.latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(matrix.options.latency * 1_000_000_000))
        }
        guard let response = matrix.handle(method: request.method.rawValue, path: request.url.path, body: request.jsonBody) else {
            return HTTPResponse(status: 404, body: Data())
        }
        return HTTPResponse(status: response.status, body: response.body)
    }
}
