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
