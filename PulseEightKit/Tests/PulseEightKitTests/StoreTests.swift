import Foundation
import Testing
@testable import PulseEightKit

@Suite struct MatrixStoreTests {
    func makeStore(
        config: MatrixConfig = MatrixConfig(host: "10.0.0.5"),
        password: String? = "secret",
        transport: MockTransport = .device(),
        clock: Clock = Clock(),
        recorder: StateRecorder = StateRecorder()
    ) -> (MatrixStore, MockTransport, Clock, StateRecorder) {
        let store = MatrixStore(
            config: config,
            adminPassword: password,
            makeTransport: { _ in transport },
            now: { clock.now },
            onChange: { recorder.record($0) }
        )
        return (store, transport, clock, recorder)
    }

    @Test func unconfiguredStoreReportsItAndRejectsActions() async throws {
        let (store, transport, _, recorder) = makeStore(config: MatrixConfig(host: nil))
        await store.start()

        let status = try #require(recorder.latest).status
        #expect(!status.configured)
        #expect(!status.connected)
        await #expect(throws: MatrixError.notConfigured) { try await store.setPort(input: 0, output: 0) }
        await #expect(throws: MatrixError.notConfigured) { try await store.reconnect() }
        #expect(transport.requests.isEmpty)
    }

    @Test func pollingPopulatesPortsDetailsSystemAndUpdates() async throws {
        let (store, _, _, recorder) = makeStore()
        await store.start()
        let state = await recorder.wait { !$0.inputDetails.isEmpty && !$0.outputDetails.isEmpty && $0.system != nil }
        await store.stop()

        let loaded = try #require(state)
        #expect(loaded.inputs.map(\.name) == ["Sky", "Apple TV"])
        #expect(loaded.outputs.map(\.name) == ["Lounge TV", "Bedroom TV"])
        #expect(loaded.status.configured)
        #expect(loaded.status.connected)
        #expect(loaded.adminConfigured)
        #expect(loaded.system?.features.backlight == .high)
        // The fixture reports a firmware update for every output.
        #expect(loaded.updates.map(\.bay) == [0, 1])
        #expect(loaded.updates.first?.name == "Lounge TV")
    }

    @Test func connectionGoesStaleAfterThreePollsOrFifteenSeconds() async throws {
        let (store, _, clock, recorder) = makeStore(config: MatrixConfig(host: "h", pollInterval: 2))
        await store.start()
        _ = await recorder.wait { $0.status.connected }

        // Polling is on a real 2s timer, so the fake clock only moves inside this instant.
        // The staleness window is max(3 * 2, 15) = 15 seconds.
        clock.advance(14)
        #expect(await store.state.status.connected)
        clock.advance(2)
        #expect(await !store.state.status.connected)
        await store.stop()
    }

    @Test func failedPollRecordsErrorAndNeverConnects() async throws {
        let transport = MockTransport { _ in .failure(TransportError("no route to host")) }
        let (store, _, _, recorder) = makeStore(transport: transport)
        await store.start()
        let state = await recorder.wait { $0.status.error != nil }
        await store.stop()

        let failed = try #require(state)
        #expect(!failed.status.connected)
        #expect(failed.status.error?.contains("no route to host") == true)
        #expect(failed.ports.isEmpty)
    }

    @Test func adminActionsRequireAPassword() async throws {
        let (store, transport, _, _) = makeStore(password: nil)
        await store.start()
        await #expect(throws: MatrixError.admin("Admin password is not set")) {
            try await store.renamePort(mode: .input, bay: 0, name: "X")
        }
        await #expect(throws: MatrixError.admin("Admin password is not set")) {
            try await store.setBacklight(.low)
        }
        await store.stop()
        #expect(!transport.summary.contains("POST /Account/Login"))
    }

    @Test func routingRefreshesPortsAfterTheWrite() async throws {
        let (store, transport, _, recorder) = makeStore()
        await store.start()
        _ = await recorder.wait { !$0.ports.isEmpty }
        let before = transport.summary.filter { $0 == "GET /Port/List" }.count

        let response = try await store.setPort(input: 1, output: 0)
        #expect(response.message == "Changed")
        await store.stop()

        let order = transport.summary
        let setIndex = try #require(order.firstIndex(of: "GET /Port/Set/1/0"))
        #expect(order[(setIndex + 1)...].contains("GET /Port/List"))
        #expect(order.filter { $0 == "GET /Port/List" }.count > before)
    }

    @Test func reconfigureSwitchesHostWithoutRestart() async throws {
        let (store, transport, _, recorder) = makeStore()
        await store.start()
        _ = await recorder.wait { !$0.ports.isEmpty }

        await store.reconfigure(config: MatrixConfig(host: "10.9.9.9", port: 81), adminPassword: nil)
        let state = await recorder.wait { $0.status.host == "10.9.9.9" && !$0.ports.isEmpty }
        await store.stop()

        let reconfigured = try #require(state)
        #expect(reconfigured.status.port == 81)
        #expect(!reconfigured.adminConfigured)
        _ = transport
    }

    @Test func edidProfilesTrackScramblingAndOutputs() async throws {
        let (store, _, _, recorder) = makeStore()
        await store.start()
        _ = await recorder.wait { $0.system != nil && !$0.ports.isEmpty }
        let ids = await store.edidProfiles().map(\.id)
        await store.stop()

        #expect(ids == [11, 4, 0, 3, 5, 2, 6, 7, 8, 101, 102])
    }
}

/// The store is an actor, but its polls `await` the network, and an actor can run other work while one is
/// suspended. A poll that was in flight when the configuration changed used to come back afterwards and
/// write the old host's answer into the new state.
@Suite struct MatrixStoreLifecycleTests {
    static let oldHost = "10.0.0.1"
    static let newHost = "10.0.0.2"

    /// `newHost` answers with ports named differently from `oldHost`, so a mix-up is visible.
    func makeTransports() -> (gated: GatedTransport, inner: MockTransport) {
        let inner = MockTransport { request in
            let isNew = request.url.host == MatrixStoreLifecycleTests.newHost
            let path = request.url.path
            let body: String
            switch path {
            case "/Port/List": body = isNew ? Fixtures.portList.replacingOccurrences(of: "Sky", with: "NewHostSky") : Fixtures.portList
            case "/System/Details": body = Fixtures.systemDetails
            case "/system/features": body = Fixtures.systemFeatures
            case let p where p.hasPrefix("/Port/Details/Input/"): body = Fixtures.inputDetails
            case let p where p.hasPrefix("/Port/Details/Output/"): body = Fixtures.outputDetails
            default: body = #"{"Result":true}"#
            }
            return MockTransport.reply(body)
        }
        return (GatedTransport(gatedHost: Self.oldHost, inner: inner), inner)
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// Gives a just-released request time to finish and be (wrongly) applied.
    func letInFlightWorkFinish() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func aPollFinishingAfterReconfigureNeverReachesTheNewConfiguration() async throws {
        let (gated, _) = makeTransports()
        let recorder = StateRecorder()
        let store = MatrixStore(
            config: MatrixConfig(host: Self.oldHost), adminPassword: nil,
            makeTransport: { _ in gated }, onChange: { recorder.record($0) }
        )
        await store.start()
        #expect(await waitUntil { gated.arrived >= 1 }, "the first poll should be in flight")

        await store.reconfigure(config: MatrixConfig(host: Self.newHost), adminPassword: nil)
        let reachedNewHost = await recorder.wait { $0.status.host == Self.newHost && $0.inputs.first?.name == "NewHostSky" }
        #expect(reachedNewHost != nil, "the new host's ports should load")

        let publishedBeforeRelease = recorder.all.count
        gated.release() // the old host finally answers
        await letInFlightWorkFinish()

        // Whatever the store ends up showing, nothing the *old* host said may be published afterwards: a UI
        // would flash the wrong matrix's ports (and a stale "connected").
        let after = recorder.all.dropFirst(publishedBeforeRelease)
        #expect(!after.contains { $0.inputs.first?.name == "Sky" }, "old host's ports were published after the switch")
        let state = await store.state
        #expect(state.inputs.first?.name == "NewHostSky")
        #expect(state.status.host == Self.newHost)
        await store.stop()
    }

    @Test func aStoppedStoreStaysEmptyEvenIfAPollWasInFlight() async throws {
        let (gated, _) = makeTransports()
        let store = MatrixStore(
            config: MatrixConfig(host: Self.oldHost), adminPassword: nil,
            makeTransport: { _ in gated }, onChange: { _ in }
        )
        await store.start()
        #expect(await waitUntil { gated.arrived >= 1 })

        await store.stop()
        gated.release()
        await letInFlightWorkFinish()

        let state = await store.state
        #expect(state.ports.isEmpty, "a poll that finished after stop() repopulated the store")
        #expect(state.system == nil)
        #expect(state.inputDetails.isEmpty && state.outputDetails.isEmpty)
        #expect(state.status.lastPollTime == nil)
        #expect(!state.status.connected)
    }

    @Test func rapidStartStopCyclesLeaveACleanStore() async throws {
        let (gated, _) = makeTransports()
        gated.release() // nothing held
        let store = MatrixStore(
            config: MatrixConfig(host: Self.oldHost), adminPassword: nil,
            makeTransport: { _ in gated }, onChange: { _ in }
        )
        for _ in 0..<40 {
            await store.start()
            await store.stop()
        }
        await letInFlightWorkFinish()

        let state = await store.state
        #expect(state.ports.isEmpty)
        #expect(!state.status.connected)
    }
}
