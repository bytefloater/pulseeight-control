import Foundation
import Testing
import PulseEightKit
@testable import PulseEightFakeMatrix

/// The real clients in PulseEightKit, run against the fake in-process (no sockets).
@Suite struct FakeMatrixContractTests {
    func clients(_ options: FakeMatrix.Options = .init()) throws -> (matrix: MatrixClient, admin: AdminClient, fake: FakeMatrix) {
        let fake = FakeMatrix(options)
        let transport = FakeMatrixTransport(fake)
        return (try MatrixClient(host: "fake", transport: transport), try AdminClient(host: "fake", transport: transport), fake)
    }

    @Test func listsEightInputsAndOutputsWithTheSampleNames() async throws {
        let ports = try await clients().matrix.ports()
        let inputs = ports.filter { $0.mode == .input }
        let outputs = ports.filter { $0.mode == .output }
        #expect(inputs.count == 8)
        #expect(outputs.count == 8)
        #expect(inputs.prefix(3).map(\.name) == ["Sky", "Apple TV", "Input 3"])
        #expect(outputs.prefix(3).map(\.name) == ["Lounge TV", "Bedroom TV", "Output 3"])
        // Every third input has no signal, like the Python original.
        #expect(inputs[2].status == .noSignal)
        #expect(outputs[0].receiveFrom == 0)
        #expect(outputs[1].receiveFrom == 1)
    }

    @Test func systemInformationDecodesLikeARealMatrixsDoes() async throws {
        let client = try clients().matrix
        let details = try await client.systemDetails()
        #expect(details.revision == Revision(main: 1, top: 2, ir: 3))
        let features = try await client.systemFeatures()
        #expect(features.hdbtUpgrade)
        #expect(features.video.ir?["Learn"] == .bool(true))
        let health = try await client.systemHealth()
        #expect(health.status == 0)
        #expect(health.rails.count == 4)
        #expect(health.temperatures.count == 5)
        #expect(health.components.count == 3)
        #expect(health.uptime != nil)
    }

    @Test func bayCountIsConfigurable() async throws {
        let ports = try await clients(.init(bays: 16)).matrix.ports()
        #expect(ports.filter { $0.mode == .input }.count == 16)
        #expect(ports.filter { $0.mode == .output }.count == 16)
    }

    @Test func routingChangesWhatAnOutputReceives() async throws {
        let client = try clients().matrix
        let response = try await client.setPort(input: 5, output: 2)
        #expect(response.message == "Changed")
        let output = try #require(try await client.ports().first { $0.mode == .output && $0.bay == 2 })
        #expect(output.receiveFrom == 5)
    }

    @Test func routingToAPortThatDoesNotExistIsRefused() async throws {
        let client = try clients().matrix
        await #expect(throws: MatrixError.api("API returned Result=false: Invalid port")) {
            _ = try await client.setPort(input: 0, output: 8)
        }
    }

    @Test func detailsReportSignalAndFirmware() async throws {
        let client = try clients().matrix
        let input = try await client.inputDetails(bay: 0)
        #expect(input.base.hasSignal == true)
        let output = try await client.outputDetails(bay: 2)
        #expect(output.firmwareVersionAvailable == true) // the sample has an update waiting on output 3
        #expect(try await client.outputDetails(bay: 0).firmwareVersionAvailable == false)
    }

    @Test func adminCallsNeedTheRightPasswordWhenOneIsSet() async throws {
        let (matrix, admin, _) = try clients(.init(password: "secret"))
        await #expect(throws: (any Error).self) {
            try await admin.renamePort(mode: .input, bay: 0, name: "Cable", password: "wrong")
        }
        try await admin.renamePort(mode: .input, bay: 0, name: "Cable", password: "secret")
        let name = try await matrix.ports().first { $0.mode == .input && $0.bay == 0 }?.name
        #expect(name == "Cable")
    }

    @Test func withNoPasswordSetAdminCallsAlwaysWork() async throws {
        let admin = try clients().admin
        try await admin.setBacklight(.low, password: "anything")
        try await admin.setStatusLED(on: false, password: "anything")
    }

    @Test func namesLongerThanTheDeviceAllowsAreRejected() async throws {
        let admin = try clients().admin
        let tooLong = String(repeating: "x", count: FakeMatrix.nameMax + 1)
        await #expect(throws: (any Error).self) {
            try await admin.renamePort(mode: .output, bay: 0, name: tooLong, password: "")
        }
        try await admin.renamePort(mode: .output, bay: 0, name: String(repeating: "x", count: FakeMatrix.nameMax), password: "")
    }

    @Test func backlightAndStatusLightAreReflectedInTheFeatures() async throws {
        let (matrix, admin, _) = try clients()
        try await admin.setBacklight(.off, password: "")
        let features = try await matrix.systemFeatures()
        #expect(features.backlight == .off)
    }
}

/// Requests the fake does not serve, and the HTTP framing of the socket server.
@Suite struct FakeMatrixRoutingTests {
    @Test func unknownPathsAreNotFound() {
        let fake = FakeMatrix()
        #expect(fake.handle(method: "GET", path: "/nope", body: nil) == nil)
        #expect(fake.handle(method: "POST", path: "/System/Details", body: nil) == nil)
        #expect(fake.handle(method: "GET", path: "/Port/Details/Sideways/0", body: nil) == nil)
    }

    @Test func pathMatchingIgnoresCaseAndTrailingSlashes() throws {
        let fake = FakeMatrix()
        let reply = try #require(fake.handle(method: "GET", path: "/SYSTEM/details/", body: nil))
        #expect(reply.status == 200)
    }

    @Test func detailsOfAMissingPortSayWhy() throws {
        let fake = FakeMatrix()
        let reply = try #require(fake.handle(method: "GET", path: "/Port/Details/Input/99", body: nil))
        let json = try #require(JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        #expect(json["Result"] as? Bool == false)
        #expect(json["Message"] as? String == "No such port")
    }
}

/// A real server on a real socket, driven with the transport the apps use on this platform.
@Suite struct FakeMatrixServerTests {
    func startServer(_ options: FakeMatrix.Options = .init()) throws -> FakeMatrixServer {
        let server = FakeMatrixServer(matrix: FakeMatrix(options), host: "127.0.0.1", port: 0)
        try server.start()
        return server
    }

    @Test func servesTheClientsOverSockets() async throws {
        let server = try startServer()
        defer { server.stop() }
        #expect(server.port != 0)

        let transport = makeDefaultTransport(timeout: 5)
        let client = try MatrixClient(host: "127.0.0.1", port: Int(server.port), transport: transport)
        let ports = try await client.ports()
        #expect(ports.count == 16)
        _ = try await client.setPort(input: 4, output: 1)
        #expect(try await client.ports().first { $0.mode == .output && $0.bay == 1 }?.receiveFrom == 4)
    }

    /// Regression for an intermittent failure of `servesTheClientsOverSockets`: stopping a server right after
    /// starting it used to leave its accept thread alive, and when that thread finally called `accept` the
    /// freed descriptor number had been reused by the next server's listener. The dead server then answered
    /// that server's clients from its own, different matrix.
    @Test func aStoppedServerNeverAnswersALaterServersClients() async throws {
        let transport = makeDefaultTransport(timeout: 5)
        // Each round starts two servers and makes new connections; Windows takes ~0.7 s a round (300 rounds was 207 s in CI).
        #if os(Windows)
        let rounds = 40
        #else
        let rounds = 300
        #endif
        for round in 0..<rounds {
            let dead = try startServer()
            dead.stop() // immediately, so its accept thread may not have started waiting yet
            let live = try startServer() // typically reuses the descriptor number `dead` just freed
            defer { live.stop() }

            let client = try MatrixClient(host: "127.0.0.1", port: Int(live.port), transport: transport)
            _ = try await client.setPort(input: 4, output: 1)
            let source = try await client.ports().first { $0.mode == .output && $0.bay == 1 }?.receiveFrom
            #expect(source == 4, "round \(round): the live server's own matrix should have answered")
            if source != 4 { break }
        }
    }

    @Test func answersUnknownPathsWith404() async throws {
        let server = try startServer()
        defer { server.stop() }
        let transport = makeDefaultTransport(timeout: 5)
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/nothing/here"))
        let response = try await transport.send(HTTPRequest(method: .get, url: url))
        #expect(response.status == 404)
    }

    @Test func postBodiesReachTheMatrix() async throws {
        let server = try startServer(.init(password: "secret"))
        defer { server.stop() }
        let transport = makeDefaultTransport(timeout: 5)
        let admin = try AdminClient(host: "127.0.0.1", port: Int(server.port), transport: transport)
        try await admin.renamePort(mode: .input, bay: 3, name: "Console", password: "secret")
        let client = try MatrixClient(host: "127.0.0.1", port: Int(server.port), transport: transport)
        #expect(try await client.ports().first { $0.mode == .input && $0.bay == 3 }?.name == "Console")
    }

    @Test func manyConcurrentRequestsAllSucceed() async throws {
        let server = try startServer()
        defer { server.stop() }
        let transport = makeDefaultTransport(timeout: 10)
        let client = try MatrixClient(host: "127.0.0.1", port: Int(server.port), transport: transport)

        let failures = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<120 {
                group.addTask {
                    do { _ = try await client.setPort(input: index % 8, output: (index / 8) % 8); return true }
                    catch { return false }
                }
            }
            var failed = 0
            for await ok in group where !ok { failed += 1 }
            return failed
        }
        #expect(failures == 0)
    }

    @Test func aStoppedServerRefusesConnections() async throws {
        let server = try startServer()
        let port = server.port
        server.stop()
        let transport = makeDefaultTransport(timeout: 2)
        let client = try MatrixClient(host: "127.0.0.1", port: Int(port), transport: transport)
        await #expect(throws: (any Error).self) { _ = try await client.ports() }
    }
}
