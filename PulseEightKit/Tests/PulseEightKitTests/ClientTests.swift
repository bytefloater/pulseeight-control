import Foundation
import Testing
@testable import PulseEightKit

@Suite struct MatrixClientTests {
    func makeClient(_ transport: MockTransport, clock: Clock = Clock()) throws -> MatrixClient {
        try MatrixClient(host: "10.0.0.5", port: 8080, transport: transport, now: { clock.now })
    }

    @Test func setPortUsesDeviceRouteAndCacheBuster() async throws {
        let transport = MockTransport.device()
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let response = try await makeClient(transport, clock: clock).setPort(input: 7, output: 5)

        #expect(response.message == "Changed")
        let request = try #require(transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "http://10.0.0.5:8080/Port/Set/7/5?_=1700000000000")
    }

    @Test func resultFalseSurfacesDeviceMessage() async throws {
        let transport = MockTransport { _ in MockTransport.reply(#"{"Result":false,"Message":"Busy"}"#) }
        await #expect(throws: MatrixError.api("API returned Result=false: Busy")) {
            _ = try await makeClient(transport).ports()
        }
    }

    @Test func nonOKStatusIsAnAPIError() async throws {
        let transport = MockTransport { _ in MockTransport.reply("", status: 503) }
        await #expect(throws: MatrixError.api("API returned status 503")) {
            _ = try await makeClient(transport).systemDetails()
        }
    }

    @Test func transportFailureIsAConnectionError() async throws {
        let transport = MockTransport { _ in .failure(TransportError("offline", isTimeout: true)) }
        await #expect(throws: MatrixError.connection("TimeoutError - Failed to connect to matrix: offline")) {
            _ = try await makeClient(transport).ports()
        }
    }

    @Test func garbageBodyIsAnAPIErrorNotACrash() async throws {
        let transport = MockTransport { _ in MockTransport.reply("<html>nope</html>") }
        do {
            _ = try await makeClient(transport).ports()
            Issue.record("expected a throw")
        } catch let error as MatrixError {
            guard case .api = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func routeByNameIsCaseInsensitiveAndFirstMatchWins() async throws {
        let transport = MockTransport.device()
        try await makeClient(transport).route(inputNamed: "APPLE tv", outputNamed: "lounge tv")
        #expect(transport.summary == ["GET /Port/List", "GET /Port/Set/1/0"])
    }

    @Test func routeByNameDistinguishesInputsFromOutputs() async throws {
        let transport = MockTransport.device()
        await #expect(throws: MatrixError.portNotFound("Input port 'Lounge TV' not found")) {
            try await makeClient(transport).route(inputNamed: "Lounge TV", outputNamed: "Bedroom TV")
        }
        await #expect(throws: MatrixError.portNotFound("Output port 'Nope' not found")) {
            try await makeClient(transport).route(inputNamed: "Sky", outputNamed: "Nope")
        }
    }
}

@Suite struct AdminClientTests {
    func makeAdmin(_ transport: MockTransport) throws -> AdminClient {
        try AdminClient(host: "10.0.0.5", transport: transport)
    }

    @Test func renameLogsInThenPosts() async throws {
        let transport = MockTransport.device()
        try await makeAdmin(transport).renamePort(mode: .output, bay: 2, name: "Garage", password: "hunter2")

        #expect(transport.summary == ["POST /Account/Login", "POST /Port/SetName/Output/2/"])
        let login = try #require(transport.requests.first?.jsonBody)
        #expect(try JSONSerialization.jsonObject(with: login) as? [String: String] == ["Password": "hunter2"])
        let rename = try #require(transport.requests.last?.jsonBody)
        #expect(try JSONSerialization.jsonObject(with: rename) as? [String: String] == ["Name": "Garage"])
    }

    @Test func renameRejectsLongNamesBeforeAnyRequest() async throws {
        let transport = MockTransport.device()
        await #expect(throws: MatrixError.admin("Name must be 13 characters or fewer")) {
            try await makeAdmin(transport).renamePort(mode: .input, bay: 0, name: "ABCDEFGHIJKLMN", password: "x")
        }
        #expect(transport.requests.isEmpty)
        // Exactly 13 is fine.
        try await makeAdmin(transport).renamePort(mode: .input, bay: 0, name: "ABCDEFGHIJKLM", password: "x")
    }

    @Test func edidIsAGetAfterLogin() async throws {
        let transport = MockTransport.device()
        try await makeAdmin(transport).setEdidProfile(bay: 3, profile: 102, password: "x")
        #expect(transport.requests.map(\.method) == [.post, .get])
        #expect(transport.summary.last == "GET /Port/EDID/Set/102/3")
    }

    @Test func frontPanelEndpoints() async throws {
        let transport = MockTransport.device()
        let admin = try makeAdmin(transport)
        try await admin.setBacklight(.low, password: "x")
        try await admin.setStatusLED(on: true, password: "x")
        try await admin.setStatusLED(on: false, password: "x")
        #expect(transport.summary.filter { $0 != "POST /Account/Login" } == [
            "POST /System/BacklightLED/low", "POST /System/StatusLED/On", "POST /System/StatusLED/Off",
        ])
    }

    @Test func failedLoginStopsBeforeTheAction() async throws {
        let transport = MockTransport { request in
            request.url.path == "/Account/Login"
                ? MockTransport.reply(#"{"Result":false,"Message":"Wrong password"}"#)
                : MockTransport.reply(#"{"Result":true}"#)
        }
        await #expect(throws: MatrixError.admin("Wrong password")) {
            try await makeAdmin(transport).setStatusLED(on: true, password: "bad")
        }
        #expect(transport.summary == ["POST /Account/Login"])
    }

    @Test func missingResultCountsAsFailure() async throws {
        let transport = MockTransport { _ in MockTransport.reply("{}") }
        await #expect(throws: MatrixError.admin("/Account/Login failed")) {
            try await makeAdmin(transport).setStatusLED(on: true, password: "x")
        }
    }

    @Test func httpErrorIsReportedWithPath() async throws {
        let transport = MockTransport { _ in MockTransport.reply("", status: 401) }
        await #expect(throws: MatrixError.admin("/Account/Login returned HTTP 401")) {
            try await makeAdmin(transport).setBacklight(.off, password: "x")
        }
    }
}
