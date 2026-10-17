import Foundation
import Testing
import PulseEightCore
import PulseEightFakeMatrix
import PulseEightKit
@testable import PulseEightControl

/// Answers like a real device but records which paths were asked for.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let inner: HTTPTransport
    private let lock = NSLock()
    private var _paths: [String] = []
    var failing = false

    init(_ inner: HTTPTransport) { self.inner = inner }

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    func count(prefix: String) -> Int { paths.filter { $0.hasPrefix(prefix) }.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        _paths.append(request.url.path)
        let fail = failing
        lock.unlock()
        if fail { throw TransportError("connection refused") }
        return try await inner.send(request)
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func secret(for account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func setSecret(_ value: String?, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = (value?.isEmpty ?? true) ? nil : value
    }
}

@MainActor
struct Harness {
    let model: AppModel
    let matrix: FakeMatrix
    let transport: RecordingTransport
    let secrets: MemorySecrets
    let settingsURL: URL

    /// A model over an in-process fake, started and (unless `host` is nil) connected.
    static func make(
        host: String? = "10.0.0.5", password: String? = "secret", savedAdminPassword: String? = "secret", bays: Int = 4,
        connect: Bool = true, unreachable: Bool = false
    ) async -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8app-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        if let host {
            var settings = AppSettings()
            settings.matrix = MatrixConfig(host: host, port: 80, timeout: 3, pollInterval: 1, detailPollInterval: 1)
            try? settings.save(to: url)
        }
        let matrix = FakeMatrix(.init(bays: bays, password: password))
        let transport = RecordingTransport(FakeMatrixTransport(matrix))
        transport.failing = unreachable // decided before the first poll, so there is no race with it
        let secrets = MemorySecrets(savedAdminPassword.map { [AppCore.adminAccount: $0] } ?? [:])
        let core = AppCore(secrets: secrets, settingsURL: url, makeTransport: { _ in transport })
        let model = AppModel(core: core)
        let harness = Harness(model: model, matrix: matrix, transport: transport, secrets: secrets, settingsURL: url)
        await model.start()
        if connect && host != nil {
            let ready = await waitUntil { model.phase == .connected && !model.ports.isEmpty && model.state?.system != nil && !(model.state?.outputDetails.isEmpty ?? true) }
            #expect(ready, "the model should connect to the fake matrix")
        }
        return harness
    }
}

/// Polls on the main actor until the condition holds.
@MainActor
func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
@Suite struct ConnectionTests {
    @Test func connectsAndPublishesBothPortLists() async throws {
        let h = await Harness.make()
        #expect(h.model.phase == .connected)
        #expect(h.model.connectionShort == "Connected")
        #expect(h.model.inputs.map(\.bay) == [0, 1, 2, 3])
        #expect(h.model.outputs.map(\.bay) == [0, 1, 2, 3])
        #expect(h.model.inputs.first?.name == "Sky")
        #expect(h.model.adminConfigured)
    }

    @Test func withNoHostItIsNotConfigured() async throws {
        let h = await Harness.make(host: nil, connect: false)
        #expect(h.model.phase == .notConfigured)
        #expect(h.model.connectionShort == "Not configured")
        #expect(h.model.ports.isEmpty)
    }

    @Test func anUnreachableMatrixShowsAsNotConnectedAndRetryWorks() async throws {
        let h = await Harness.make(connect: false, unreachable: true)
        #expect(await waitUntil { if case .disconnected = h.model.phase { true } else { false } })
        #expect(h.model.connectionShort == "Not connected")

        h.transport.failing = false
        h.model.retry()
        #expect(await waitUntil { h.model.phase == .connected }, "retry should reconnect once the matrix is back")
        #expect(await waitUntil { !h.model.retrying })
    }
}

@MainActor
@Suite struct RoutingTests {
    @Test func aRouteIsPendingUntilTheMatrixConfirmsIt() async throws {
        let h = await Harness.make()
        h.model.route(input: 2, output: 1)
        #expect(h.model.pendingRoutes.contains(RouteKey(input: 2, output: 1)))

        #expect(await waitUntil { h.model.pendingRoutes.isEmpty })
        #expect(h.model.outputs.first { $0.bay == 1 }?.receiveFrom == 2)
        #expect(h.model.routeError == nil)
    }

    @Test func clickingTheSameRouteTwiceSendsItOnce() async throws {
        let h = await Harness.make()
        h.model.route(input: 3, output: 0)
        h.model.route(input: 3, output: 0)
        h.model.route(input: 3, output: 0)
        #expect(await waitUntil { h.model.pendingRoutes.isEmpty })
        #expect(h.transport.count(prefix: "/Port/Set/") == 1)
    }

    @Test func aRouteTheMatrixRefusesShowsAnErrorAndClearsPending() async throws {
        let h = await Harness.make()
        h.model.route(input: 0, output: 99)
        #expect(await waitUntil { h.model.routeError != nil })
        #expect(h.model.routeError?.hasPrefix("Failed to set route:") == true)
        #expect(await waitUntil { h.model.pendingRoutes.isEmpty })
    }
}

@MainActor
@Suite struct PortEditingTests {
    @Test func openingAPortLoadsItsCurrentNameAndEdidProfile() async throws {
        let h = await Harness.make()
        h.model.openPort(PortSelection(mode: .input, bay: 1))
        #expect(h.model.selectedPort == PortSelection(mode: .input, bay: 1))
        #expect(h.model.portEdit.name == "Apple TV")
        #expect(h.model.portEdit.edidProfile != nil)
        #expect(h.model.portEdit.error == nil)

        h.model.openPort(PortSelection(mode: .output, bay: 0))
        #expect(h.model.portEdit.name == "Lounge TV")
        #expect(h.model.portEdit.edidProfile == nil, "outputs have no EDID profile")
    }

    @Test func renamingAPortReachesTheMatrixAndComesBack() async throws {
        let h = await Harness.make()
        h.model.openPort(PortSelection(mode: .output, bay: 0))
        h.model.portEdit.name = "  Den  "
        h.model.savePortEdit()

        #expect(await waitUntil { !h.model.portEdit.saving })
        #expect(h.model.portEdit.error == nil)
        #expect(h.model.portEdit.name == "Den", "the field shows the trimmed name that was sent")
        #expect(await waitUntil { h.model.outputs.first { $0.bay == 0 }?.name == "Den" }, "the new name should appear after the next poll")
    }

    @Test func aNameThatIsTooLongIsRejectedBeforeAnythingIsSent() async throws {
        let h = await Harness.make()
        h.model.openPort(PortSelection(mode: .output, bay: 0))
        h.model.portEdit.name = "this name is much too long"
        h.model.savePortEdit()

        #expect(h.model.portEdit.error != nil)
        #expect(!h.model.portEdit.saving)
        #expect(h.transport.count(prefix: "/Port/SetName") == 0)
        #expect(h.transport.count(prefix: "/Account/Login") == 0)
    }

    @Test func anEmptyNameIsRejected() async throws {
        let h = await Harness.make()
        h.model.openPort(PortSelection(mode: .input, bay: 0))
        h.model.portEdit.name = "   "
        h.model.savePortEdit()
        #expect(h.model.portEdit.error != nil)
        #expect(h.transport.count(prefix: "/Port/SetName") == 0)
    }

    @Test func withoutAnAdminPasswordTheEditFailsWithAMessage() async throws {
        let h = await Harness.make(savedAdminPassword: nil)
        #expect(!h.model.adminConfigured)
        h.model.openPort(PortSelection(mode: .output, bay: 0))
        h.model.portEdit.name = "Den"
        h.model.savePortEdit()

        #expect(await waitUntil { !h.model.portEdit.saving })
        #expect(h.model.portEdit.error != nil)
        #expect(h.model.outputs.first { $0.bay == 0 }?.name == "Lounge TV")
    }

    @Test func aWrongAdminPasswordIsReportedAndChangesNothing() async throws {
        let h = await Harness.make(savedAdminPassword: "not the password")
        h.model.openPort(PortSelection(mode: .output, bay: 0))
        h.model.portEdit.name = "Den"
        h.model.savePortEdit()

        #expect(await waitUntil { !h.model.portEdit.saving })
        #expect(h.model.portEdit.error != nil)
        #expect(h.model.outputs.first { $0.bay == 0 }?.name == "Lounge TV")
    }

    @Test func changingAnInputsEdidProfileIsSentAndShownBack() async throws {
        let h = await Harness.make()
        h.model.openPort(PortSelection(mode: .input, bay: 2))
        let current = try #require(h.model.portEdit.edidProfile)
        let other = try #require(h.model.core.edidProfiles().map(\.id).first { $0 != current })
        h.model.portEdit.edidProfile = other
        h.model.savePortEdit()

        #expect(await waitUntil { !h.model.portEdit.saving })
        #expect(h.model.portEdit.error == nil)
        #expect(await waitUntil { h.model.state?.inputDetails[2]?.edidProfile == other })
        #expect(h.transport.count(prefix: "/Port/SetName") == 0, "an unchanged name isn't resent")
    }
}

@MainActor
@Suite struct FrontPanelTests {
    @Test func theBacklightIsPendingThenConfirmed() async throws {
        let h = await Harness.make()
        h.model.setBacklight(.low)
        #expect(h.model.backlightPending == .low)
        #expect(await waitUntil { h.model.backlightPending == nil })
        #expect(h.model.state?.system?.features.backlight == .low)
        #expect(h.model.frontPanelError == nil)
    }

    @Test func theStatusLightIsPendingThenConfirmed() async throws {
        let h = await Harness.make()
        h.model.setStatusLED(on: false)
        #expect(h.model.statusLEDPending == false)
        #expect(await waitUntil { h.model.statusLEDPending == nil })
        #expect(h.model.state?.system?.features.statusLEDOn == false)
    }

    @Test func withoutAnAdminPasswordTheErrorIsShownAndTheControlReleased() async throws {
        let h = await Harness.make(savedAdminPassword: nil)
        h.model.setBacklight(.off)
        #expect(await waitUntil { h.model.backlightPending == nil })
        #expect(h.model.frontPanelError != nil)
        #expect(h.model.state?.system?.features.backlight != BacklightLevel.off)
    }

    @Test func aSecondChangeWhileOneIsPendingIsIgnored() async throws {
        let h = await Harness.make()
        h.model.setBacklight(.low)
        h.model.setBacklight(.off)
        #expect(h.model.backlightPending == .low)
        #expect(await waitUntil { h.model.backlightPending == nil })
        #expect(h.model.state?.system?.features.backlight == .low)
    }
}

@MainActor
@Suite struct SettingsTests {
    @Test func theDraftStartsFromTheSavedSettings() async throws {
        let h = await Harness.make()
        #expect(h.model.draft.host == "10.0.0.5")
        #expect(h.model.draft.port == "80")
        #expect(h.model.draft.adminPassword.isEmpty, "the saved password is never shown")
    }

    @Test func invalidInputIsRefusedWithAMessageAndNothingIsSaved() async throws {
        let h = await Harness.make()
        h.model.draft.port = "not a port"
        h.model.saveSettings()

        #expect(h.model.settingsMessage?.isError == true)
        #expect(h.model.settings.matrix.port == 80)
        #expect(AppSettings.load(from: h.settingsURL).matrix.port == 80)
    }

    @Test func savingAppliesPersistsAndTrimsTheHost() async throws {
        let h = await Harness.make()
        h.model.draft.host = "  10.0.0.9  "
        h.model.draft.port = "8081"
        h.model.saveSettings()

        #expect(h.model.settingsMessage?.isError == false)
        #expect(h.model.draft.host == "10.0.0.9")
        #expect(await waitUntil { h.model.settings.matrix.host == "10.0.0.9" })
        let saved = AppSettings.load(from: h.settingsURL).matrix
        #expect(saved.host == "10.0.0.9")
        #expect(saved.port == 8081)
    }

    @Test func resettingTheDraftDiscardsUnsavedEdits() async throws {
        let h = await Harness.make()
        h.model.draft.host = "somewhere.else"
        h.model.settingsMessage = ("old message", true)
        h.model.resetDraft()
        #expect(h.model.draft.host == "10.0.0.5")
        #expect(h.model.settingsMessage == nil)
    }

    @Test func theAdminPasswordCanBeSavedAndRemoved() async throws {
        let h = await Harness.make(savedAdminPassword: nil)
        #expect(!h.model.adminConfigured)

        h.model.draft.adminPassword = "secret"
        h.model.saveSettings()
        #expect(h.model.draft.adminPassword.isEmpty, "the field is cleared after saving")
        #expect(try h.secrets.secret(for: AppCore.adminAccount) == "secret")
        #expect(await waitUntil { h.model.adminConfigured })

        h.model.removeAdminPassword()
        #expect(h.model.settingsMessage?.isError == false)
        #expect(try h.secrets.secret(for: AppCore.adminAccount) == nil)
        #expect(await waitUntil { !h.model.adminConfigured })
    }

    @Test func appearanceAppliesAtOnceAndIsSaved() async throws {
        let h = await Harness.make()
        h.model.setAppearance(.dark)
        #expect(h.model.draft.appearance == .dark)
        #expect(await waitUntil { h.model.settings.appearance == .dark })
        #expect(AppSettings.load(from: h.settingsURL).appearance == .dark)
    }

    @Test func viewPreferencesArePersisted() async throws {
        let h = await Harness.make()
        h.model.setHighlightGrid(false)
        h.model.setShowStatusBar(false)
        #expect(await waitUntil { !h.model.settings.highlightGrid && !h.model.settings.showStatusBar })
        let saved = AppSettings.load(from: h.settingsURL)
        #expect(!saved.highlightGrid && !saved.showStatusBar)
    }
}
