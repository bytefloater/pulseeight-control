import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

/// Answers the matrix's read endpoints from fixed JSON and records requests.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var fail = false

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        _paths.append(request.url.path)
        let failing = fail
        lock.unlock()
        if failing { throw TransportError("connection refused") }
        let body: String
        switch request.url.path {
        case "/Port/List":
            body = #"{"Result":true,"Ports":[{"Bay":0,"Mode":"Input","Type":"HDMI IN","Status":0,"Name":"Sky"},{"Bay":0,"Mode":"Output","Type":"HDBT OUT","Status":0,"Name":"Lounge","ReceiveFrom":0}]}"#
        case "/System/Details":
            body = #"{"Result":true,"Model":"NeoMatrix","Version":"1.2.3","Serial":"S","MAC":"m","VID":"v","BoardRev":2,"Revision":{"Main":1,"Top":2,"Ir":3},"Locale":"en","StatusMessage":"OK","Status":0}"#
        case "/system/features":
            body = #"{"Result":true,"UpdInterval":5000,"CEC":1,"CEC_Switching":false,"CEC_Logging":0,"CEC_Usage":1,"PDU":false,"Sky":true,"HDBaseT":true,"HdbtUpgrade":true,"MxRemote":false,"Video":{"Scrambling":true,"Input":{},"Output":{}},"Audio":{"Routing":true,"Input":{},"Output":{}},"BacklightLED":"High","StatusLED":"On"}"#
        default:
            body = #"{"Result":true,"Message":"Changed"}"#
        }
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func setSecret(_ value: String?, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = (value?.isEmpty ?? true) ? nil : value
    }
}

@Suite struct AppCoreTests {
    func makeCore(
        host: String? = nil, transport: FakeTransport = FakeTransport(), secrets: MemorySecrets = MemorySecrets()
    ) throws -> (AppCore, FakeTransport, MemorySecrets, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8core-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        if let host {
            var settings = AppSettings()
            settings.matrix = MatrixConfig(host: host, port: 80, timeout: 3, pollInterval: 1, detailPollInterval: 1)
            try settings.save(to: url)
        }
        let core = AppCore(secrets: secrets, settingsURL: url, makeTransport: { _ in transport })
        return (core, transport, secrets, url)
    }

    func waitUntil(_ core: AppCore, timeout: TimeInterval = 5, _ condition: (AppCore) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(core) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    @Test func startsNotConfiguredWithoutAHost() throws {
        let (core, _, _, _) = try makeCore()
        #expect(core.phase == .notConfigured)
        #expect(core.connectionSummary == "Not configured")
    }

    @Test func connectsAndExposesTheMatrix() async throws {
        let (core, _, _, _) = try makeCore(host: "10.0.0.5")
        #expect(core.phase == .connecting)
        await core.start()
        #expect(await waitUntil(core) { $0.phase == .connected })
        #expect(core.connectionSummary == "Connected to 10.0.0.5")
        #expect(core.state?.inputs.first?.name == "Sky")
    }

    @Test func reportsAnUnreachableMatrix() async throws {
        let transport = FakeTransport()
        transport.fail = true
        let (core, _, _, _) = try makeCore(host: "10.0.0.5", transport: transport)
        await core.start()
        #expect(await waitUntil(core) { if case .disconnected = $0.phase { true } else { false } })
    }

    @Test func settingsValidationGivesReadyToShowMessages() throws {
        let (core, _, _, _) = try makeCore()
        let cases: [(SettingsInput, String)] = [
            (SettingsInput(host: "  "), "IP address"),
            (SettingsInput(host: "h", port: "0"), "1 to 65535"),
            (SettingsInput(host: "h", port: "abc"), "1 to 65535"),
            (SettingsInput(host: "h", timeout: "0"), "Timeout"),
            (SettingsInput(host: "h", pollInterval: "-1"), "Poll interval"),
            (SettingsInput(host: "h", detailPollInterval: "x"), "Detail poll"),
        ]
        for (input, fragment) in cases {
            #expect {
                try core.saveSettings(input)
            } throws: { error in
                (error as? CoreError).map { $0.errorDescription?.contains(fragment) == true } ?? false
            }
        }
        #expect(core.settings.matrix.host == nil)
    }

    @Test func savingPersistsSettingsAndTheAdminPassword() async throws {
        let (core, _, secrets, url) = try makeCore()
        try core.saveSettings(SettingsInput(host: " 10.0.0.9 ", port: "8080", adminPassword: "pw"))
        #expect(core.settings.matrix.host == "10.0.0.9")
        #expect(core.settings.matrix.port == 8080)
        #expect(try secrets.secret(for: AppCore.adminAccount) == "pw")
        #expect(AppSettings.load(from: url).matrix.host == "10.0.0.9")
        #expect(core.phase == .connecting)
        // The password never lands in the settings file.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("pw"))
    }

    @Test func observersHearAboutChangesButNotQuietPolls() async throws {
        let (core, _, _, _) = try makeCore(host: "10.0.0.5")
        let count = Counter()
        core.addObserver { _ in count.increment() }
        await core.start()
        #expect(await waitUntil(core) { $0.phase == .connected })
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterConnect = count.value
        #expect(afterConnect > 0)
        // More polls arrive (1s interval) but carry only new timestamps.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(count.value == afterConnect)
    }

    @Test func portNamesAreValidatedLikeTheMatrix() throws {
        let (core, _, _, _) = try makeCore()
        #expect(try core.validatePortName("  Sky  ") == "Sky")
        #expect(throws: CoreError.invalid("Name can't be empty.")) { try core.validatePortName("   ") }
        #expect(throws: CoreError.self) { try core.validatePortName("12345678901234") }
        // Counted in unicode scalars, as the matrix's own field is.
        #expect(try core.validatePortName("1234567890123") == "1234567890123")
    }

    @Test func commandsBeforeStartFailCleanly() async throws {
        let (core, _, _, _) = try makeCore(host: "10.0.0.5")
        let response = await core.handle(requestJSON: #"{"cmd":"route","input":0,"output":0}"#)
        #expect(response.contains(#""ok":false"#))
    }

    @Test func jsonCommandsRouteAndReportErrors() async throws {
        let (core, transport, _, _) = try makeCore(host: "10.0.0.5")
        await core.start()
        #expect(await waitUntil(core) { $0.phase == .connected })

        #expect(await core.handle(requestJSON: #"{"cmd":"route","input":0,"output":0}"#) == #"{"ok":true}"#)
        #expect(transport.paths.contains("/Port/Set/0/0"))

        let missing = await core.handle(requestJSON: #"{"cmd":"route","input":0}"#)
        #expect(missing.contains("Missing number field"))
        #expect(await core.handle(requestJSON: "not json").contains(#""ok":false"#))
        #expect(await core.handle(requestJSON: #"{"cmd":"bogus"}"#).contains("Unknown command"))
        #expect(await core.handle(requestJSON: #"{"cmd":"setBacklight","level":"loud"}"#).contains("off, low or high"))
    }

    @Test func snapshotUsesStableNamesAndSharedText() async throws {
        let (core, _, _, _) = try makeCore(host: "10.0.0.5")
        await core.start()
        #expect(await waitUntil(core) { $0.state?.system != nil })

        let json = CoreSnapshot(core: core).jsonString()
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["phase"] as? String == "connected")
        #expect((object["inputs"] as? [[String: Any]])?.first?["name"] as? String == "Sky")
        let outputs = try #require(object["outputs"] as? [[String: Any]])
        #expect(outputs.first?["sourceName"] as? String == "Sky")
        let features = try #require(object["featureRows"] as? [[String: String]])
        #expect(features.contains { $0["label"] == "Update interval" && $0["value"] == "5s" })
        let frontPanel = try #require(object["frontPanel"] as? [String: Any])
        #expect(frontPanel["backlight"] as? String == "high")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
