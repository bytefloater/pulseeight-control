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
    /// The matrix `host` configured, when there is one.
    let matrixID: UUID

    /// A model over an in-process fake, started and (unless `host` is nil) connected.
    static func make(
        host: String? = "10.0.0.5", password: String? = "secret", savedAdminPassword: String? = "secret", bays: Int = 4,
        connect: Bool = true, unreachable: Bool = false, connectionGrace: Duration = .zero,
        restartOutage: TimeInterval = 0, restartWatch: Duration = .seconds(45)
    ) async -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8app-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        let matrixID = UUID()
        if let host {
            var settings = AppSettings()
            settings.matrices = [MatrixProfile(id: matrixID, config: MatrixConfig(host: host, port: 80, timeout: 3, pollInterval: 1, detailPollInterval: 1))]
            settings.selectedMatrixID = matrixID
            try? settings.save(to: url)
        }
        let matrix = FakeMatrix(.init(bays: bays, password: password, restartOutage: restartOutage))
        let transport = RecordingTransport(FakeMatrixTransport(matrix))
        transport.failing = unreachable // decided before the first poll, so there is no race with it
        let secrets = MemorySecrets(savedAdminPassword.map { [AppCore.adminAccount(for: matrixID): $0] } ?? [:])
        let core = AppCore(secrets: secrets, settingsURL: url, makeTransport: { _ in transport })
        let model = AppModel(core: core, localNetwork: .disabled, connectionGrace: connectionGrace, restartWatch: restartWatch)
        let harness = Harness(model: model, matrix: matrix, transport: transport, secrets: secrets, settingsURL: url, matrixID: matrixID)
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

    @Test func theMatrixsHealthReportReachesTheModel() async throws {
        let h = await Harness.make()
        #expect(await waitUntil { h.model.state?.health != nil })
        let health = try #require(h.model.state?.health)
        #expect(health.statusMessage == "Healthy")
        #expect(health.temperatures.count == 5)
        #expect(health.rails.contains { $0.name == "12V" })
        #expect(await waitUntil { h.model.state?.monitoring != nil })
        #expect(h.model.state?.monitoring?.cloudConnected == true)
    }

    @Test func aFailureInsideTheGracePeriodStillLooksLikeConnecting() async throws {
        let h = await Harness.make(connect: false, unreachable: true, connectionGrace: .milliseconds(600))
        #expect(await waitUntil { if case .disconnected = h.model.phase { true } else { false } })

        // The attempt has failed, but it is still early: the screen doesn't say so yet.
        #expect(h.model.inGracePeriod)
        #expect(h.model.displayPhase == .connecting)
        #expect(h.model.connectionShort == "Connecting…")
        #expect(h.model.connectionSummary.hasPrefix("Connecting"))

        // Once the grace is used up it does.
        #expect(await waitUntil { !h.model.inGracePeriod })
        #expect(h.model.displayPhase == h.model.phase)
        #expect(h.model.connectionShort == "Not connected")
    }

    @Test func connectingEndsTheGracePeriodAtOnce() async throws {
        let h = await Harness.make(connectionGrace: .seconds(30))
        #expect(h.model.phase == .connected)
        #expect(!h.model.inGracePeriod, "no need to wait out the grace once the matrix has answered")
        #expect(h.model.displayPhase == .connected)
    }

    @Test func retryingGivesTheNewAttemptItsOwnGrace() async throws {
        let h = await Harness.make(connect: false, unreachable: true, connectionGrace: .milliseconds(300))
        #expect(await waitUntil { !h.model.inGracePeriod && { if case .disconnected = h.model.phase { true } else { false } }() })
        #expect(h.model.connectionShort == "Not connected")

        h.model.retry()
        #expect(h.model.inGracePeriod)
        #expect(h.model.connectionShort == "Connecting…")
        #expect(await waitUntil { !h.model.inGracePeriod })
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
    @Test func editingStartsFromTheSavedMatrix() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(h.matrixID)
        #expect(h.model.matrixDraft.host == "10.0.0.5")
        #expect(h.model.matrixDraft.port == "80")
        #expect(h.model.matrixDraft.adminPassword.isEmpty, "the saved password is never shown")
        #expect(h.model.matrixDraft.adminPasswordSaved)
        #expect(h.model.matrixMessage == nil)
    }

    @Test func addingStartsFromAnEmptyForm() async throws {
        let h = await Harness.make()
        h.model.matrixDraft.host = "left over"
        h.model.beginEditingMatrix(nil)
        #expect(h.model.matrixDraft == MatrixDraft())
    }

    @Test func invalidInputIsRefusedWithAMessageAndNothingIsSaved() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(h.matrixID)
        h.model.matrixDraft.port = "not a port"

        #expect(!h.model.saveMatrixDraft())
        #expect(h.model.matrixMessage?.isError == true)
        #expect(h.model.settings.matrix.port == 80)
        #expect(AppSettings.load(from: h.settingsURL).matrix.port == 80)
    }

    @Test func savingAnEditAppliesPersistsAndTrimsTheHost() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(h.matrixID)
        h.model.matrixDraft.name = "Lounge"
        h.model.matrixDraft.host = "  10.0.0.9  "
        h.model.matrixDraft.port = "8081"

        #expect(h.model.saveMatrixDraft())
        #expect(h.model.matrixMessage == nil)
        #expect(await waitUntil { h.model.settings.matrix.host == "10.0.0.9" })
        #expect(h.model.matrices.count == 1)
        let saved = AppSettings.load(from: h.settingsURL).selectedMatrix
        #expect(saved?.name == "Lounge")
        #expect(saved?.config.host == "10.0.0.9")
        #expect(saved?.config.port == 8081)
        #expect(h.model.hostLabel == "Lounge")
    }

    @Test func savingANewMatrixAddsItWithoutSwitchingToIt() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(nil)
        h.model.matrixDraft.name = "Cinema"
        h.model.matrixDraft.host = "10.0.0.20"

        #expect(h.model.saveMatrixDraft())
        #expect(await waitUntil { h.model.matrices.count == 2 })
        #expect(h.model.matrices.last?.name == "Cinema")
        #expect(h.model.selectedMatrixID == h.matrixID, "adding doesn't change which matrix is shown")
    }

    @Test func selectingAMatrixSwitchesTheConnection() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(nil)
        h.model.matrixDraft.name = "Cinema"
        h.model.matrixDraft.host = "10.0.0.20"
        h.model.saveMatrixDraft()
        #expect(await waitUntil { h.model.matrices.count == 2 })
        let cinema = try #require(h.model.matrices.last).id

        h.model.pendingRoutes = [RouteKey(input: 0, output: 0)]
        h.model.selectMatrix(id: cinema)

        #expect(h.model.pendingRoutes.isEmpty, "routes sent to the old matrix mean nothing to the new one")
        #expect(await waitUntil { h.model.selectedMatrixID == cinema })
        #expect(h.model.settings.matrix.host == "10.0.0.20")
        #expect(AppSettings.load(from: h.settingsURL).selectedMatrix?.id == cinema)
        // The fake answers on every host, so the new matrix connects too.
        #expect(await waitUntil { h.model.phase == .connected && h.model.hostLabel == "Cinema" })
        #expect(!h.model.adminConfigured, "the other matrix has no admin password")
    }

    @Test func removingTheShownMatrixFallsBackToAnother() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(nil)
        h.model.matrixDraft.host = "10.0.0.20"
        h.model.saveMatrixDraft()
        #expect(await waitUntil { h.model.matrices.count == 2 })
        let other = try #require(h.model.matrices.last).id

        h.model.removeMatrix(id: h.matrixID)
        #expect(await waitUntil { h.model.matrices.map(\.id) == [other] })
        #expect(h.model.selectedMatrixID == other)
        #expect(try h.secrets.secret(for: AppCore.adminAccount(for: h.matrixID)) == nil)
    }

    @Test func theAdminPasswordCanBeSavedAndRemovedPerMatrix() async throws {
        let h = await Harness.make(savedAdminPassword: nil)
        #expect(!h.model.adminConfigured)

        h.model.beginEditingMatrix(h.matrixID)
        h.model.matrixDraft.adminPassword = "secret"
        #expect(h.model.saveMatrixDraft())
        #expect(try h.secrets.secret(for: AppCore.adminAccount(for: h.matrixID)) == "secret")
        #expect(await waitUntil { h.model.adminConfigured })

        h.model.beginEditingMatrix(h.matrixID)
        #expect(h.model.matrixDraft.adminPasswordSaved)
        h.model.matrixDraft.clearAdminPassword = true
        #expect(h.model.saveMatrixDraft())
        #expect(try h.secrets.secret(for: AppCore.adminAccount(for: h.matrixID)) == nil)
        #expect(await waitUntil { !h.model.adminConfigured })
    }

    @Test func appearanceAppliesAtOnceAndIsSaved() async throws {
        let h = await Harness.make()
        h.model.setAppearance(.dark)
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

/// Every test here runs against the in-process fake matrix: nothing may restart a real one.
@MainActor
@Suite struct RestartTests {
    @Test func askingToRestartOnlyRaisesTheQuestion() async throws {
        let h = await Harness.make()
        #expect(h.model.requestRestart())
        #expect(h.model.confirmingRestart)
        #expect(h.matrix.restartCount == 0, "nothing is sent until the person confirms")
        #expect(!h.model.isRestarting)
    }

    @Test func withoutAnAdminPasswordThereIsNothingToConfirm() async throws {
        let h = await Harness.make(savedAdminPassword: nil)
        #expect(!h.model.requestRestart())
        #expect(!h.model.confirmingRestart)
        h.model.restartMatrix()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.matrix.restartCount == 0)
    }

    @Test func confirmingSendsTheRestartOnce() async throws {
        let h = await Harness.make(restartWatch: .milliseconds(300))
        h.model.requestRestart()
        h.model.restartMatrix()
        #expect(!h.model.confirmingRestart)
        #expect(await waitUntil { h.model.isRestarting })
        #expect(await waitUntil { h.matrix.restartCount == 1 })

        h.model.restartMatrix() // pressed again while it is restarting
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.matrix.restartCount == 1)
    }

    @Test func whileRestartingTheWindowSaysSoInsteadOfAnError() async throws {
        let h = await Harness.make(restartOutage: 1.5)
        h.model.restartMatrix()
        #expect(await waitUntil { h.model.isRestarting })
        #expect(h.model.displayPhase == .connecting)
        #expect(h.model.connectionShort == "Restarting…")
        #expect(h.model.connectionSummary.hasPrefix("Restarting"))
    }

    @Test func itIsRestartingUntilTheMatrixHasGoneAwayAndComeBack() async throws {
        let h = await Harness.make(restartOutage: 1.5)
        h.model.restartMatrix()
        #expect(await waitUntil { h.model.isRestarting })

        // Unreachable for the outage, then answering again: the restart is over.
        #expect(await waitUntil(timeout: 12) { !h.model.isRestarting })
        #expect(await waitUntil { h.model.phase == .connected })
        #expect(h.model.displayPhase == .connected)
        #expect(h.matrix.restartCount == 1)
    }

    @Test func aRestartThatNeverTakesEffectStopsBeingShownAsOne() async throws {
        let h = await Harness.make(restartWatch: .milliseconds(400)) // the fake stays reachable throughout
        h.model.restartMatrix()
        #expect(await waitUntil { h.model.isRestarting })
        #expect(await waitUntil(timeout: 8) { !h.model.isRestarting })
        #expect(h.model.phase == .connected)
    }

    @Test func aRefusedRestartIsReportedAndNeverLooksLikeOne() async throws {
        let h = await Harness.make(password: "right", savedAdminPassword: "wrong")
        h.model.restartMatrix()
        #expect(await waitUntil { h.model.restartError != nil })
        #expect(!h.model.isRestarting)
        #expect(h.matrix.restartCount == 0)
    }
}
