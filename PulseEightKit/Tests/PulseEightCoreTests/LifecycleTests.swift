import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

/// A core that is stopped, or simply let go of, must stop talking to the matrix. The C interface relies on
/// this: `p8_destroy` is the only teardown the Windows app has.
@Suite struct AppCoreLifecycleTests {
    func makeCore(transport: FakeTransport) throws -> AppCore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8core-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        var settings = AppSettings()
        settings.matrix = MatrixConfig(host: "10.0.0.5", port: 80, timeout: 3, pollInterval: 1, detailPollInterval: 1)
        try settings.save(to: url)
        return AppCore(secrets: MemorySecrets(), settingsURL: url, makeTransport: { _ in transport })
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    @Test func aCoreThatIsLetGoStopsPolling() async throws {
        let transport = FakeTransport()
        do {
            let core = try makeCore(transport: transport)
            await core.start()
            #expect(await waitUntil { !transport.paths.isEmpty }, "it should start polling")
        } // the core is released here

        try await Task.sleep(nanoseconds: 300_000_000) // let anything in flight finish
        let settled = transport.paths.count
        try await Task.sleep(nanoseconds: 2_500_000_000) // longer than two poll intervals
        #expect(transport.paths.count == settled, "polling carried on after the core was released")
    }
}

extension AppCoreLifecycleTests {
    @Test func stopEndsPollingAndLeavesNothingConnected() async throws {
        let transport = FakeTransport()
        let core = try makeCore(transport: transport)
        await core.start()
        #expect(await waitUntil { core.phase == .connected }, "it should connect first")

        await core.stop()
        #expect(core.state == nil)
        #expect(core.phase == .connecting) // a host is saved, but nothing is connected
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = transport.paths.count
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(transport.paths.count == settled, "polling carried on after stop()")
    }

    @Test func aStoppedCoreCanBeStartedAgain() async throws {
        let transport = FakeTransport()
        let core = try makeCore(transport: transport)
        await core.start()
        #expect(await waitUntil { core.phase == .connected })
        await core.stop()

        await core.start()
        #expect(await waitUntil { core.phase == .connected }, "restarting should connect again")
        await core.stop()
    }

    @Test func stoppedObserversHearNothingMore() async throws {
        let transport = FakeTransport()
        let core = try makeCore(transport: transport)
        let heard = Counter()
        core.addObserver { _ in heard.increment() }
        await core.start()
        #expect(await waitUntil { heard.value > 0 })

        await core.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = heard.value
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(heard.value == settled, "an observer was notified after stop()")
    }
}
