import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

/// Answers every request with one canned response, as the discovery service would.
private struct ServiceTransport: HTTPTransport {
    var response: Result<HTTPResponse, TransportError>
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { try response.get() }
}

@Suite struct DiscoveryCommandTests {
    func makeCore(_ response: Result<HTTPResponse, TransportError>) -> (AppCore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8discover-\(UUID().uuidString)").appendingPathComponent("settings.json")
        let core = AppCore(secrets: MemorySecrets(), settingsURL: url, makeTransport: { _ in ServiceTransport(response: response) })
        return (core, url)
    }

    static let found = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 302, body: Data(), location: "http://192.168.1.50:8080/"))
    static let none = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 200, body: Data("no matrix".utf8)))

    @Test func findsTheMatrixWithoutChangingSettings() async throws {
        let (core, url) = makeCore(Self.found)
        let matrix = try await core.discoverMatrix()
        #expect(matrix == DiscoveredMatrix(host: "192.168.1.50", port: 8080))
        #expect(core.settings.matrix.host == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func nothingFoundIsNil() async throws {
        let (core, _) = makeCore(Self.none)
        #expect(try await core.discoverMatrix() == nil)
    }

    @Test func serviceFailureIsAShowableError() async {
        let (core, _) = makeCore(.failure(TransportError("offline")))
        await #expect(throws: CoreError.failed("Couldn't reach gotomymatrix.com: offline")) {
            _ = try await core.discoverMatrix()
        }
    }

    @Test func discoverCommandReturnsHostAndPort() async throws {
        let (core, _) = makeCore(Self.found)
        #expect(await core.handle(requestJSON: #"{"cmd":"discover"}"#) == #"{"ok":true,"value":"{\"host\":\"192.168.1.50\",\"port\":8080}"}"#)
    }

    @Test func discoverCommandWithNothingFoundHasNoValue() async {
        let (core, _) = makeCore(Self.none)
        #expect(await core.handle(requestJSON: #"{"cmd":"discover"}"#) == #"{"ok":true}"#)
    }

    @Test func discoverCommandReportsFailure() async {
        let (core, _) = makeCore(.failure(TransportError("offline")))
        #expect(await core.handle(requestJSON: #"{"cmd":"discover"}"#) == #"{"error":"Couldn't reach gotomymatrix.com: offline","ok":false}"#)
    }
}
