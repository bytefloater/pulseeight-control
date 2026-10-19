import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

@Suite struct MatricesTests {
    func makeCore(file: String? = nil, secrets: MemorySecrets = MemorySecrets()) throws -> (AppCore, MemorySecrets, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p8matrices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        if let file { try file.write(to: url, atomically: true, encoding: .utf8) }
        return (AppCore(secrets: secrets, settingsURL: url, makeTransport: { _ in FakeTransport() }), secrets, url)
    }

    func password(_ secrets: MemorySecrets, _ id: UUID) throws -> String? { try secrets.secret(for: AppCore.adminAccount(for: id)) }

    // MARK: The file

    @Test func aFileWithOneMatrixBecomesTheFirstMatrixAndIsRewritten() throws {
        let legacy = #"{"matrix":{"host":"10.0.0.9","port":8080,"timeout":3,"poll_interval":2,"detail_poll_interval":9},"appearance":"dark"}"#
        let (core, _, url) = try makeCore(file: legacy)

        let matrix = try #require(core.selectedMatrix)
        #expect(core.matrices.count == 1)
        #expect(matrix.name == "10.0.0.9")
        #expect(matrix.config == MatrixConfig(host: "10.0.0.9", port: 8080, timeout: 3, pollInterval: 2, detailPollInterval: 9))
        #expect(core.settings.appearance == .dark)

        // Rewritten in the current form, so the id the password is filed under is stable.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"matrices\""))
        #expect(!text.contains("\"matrix\""))
        #expect(AppSettings.load(from: url).selectedMatrix?.id == matrix.id)
    }

    @Test func theSavedAdminPasswordMovesToTheMigratedMatrix() throws {
        let legacy = #"{"matrix":{"host":"10.0.0.9"}}"#
        let saved = MemorySecrets()
        try saved.setSecret("old", for: "admin-password")
        let (core, secrets, _) = try makeCore(file: legacy, secrets: saved)
        #expect(try password(secrets, try #require(core.selectedMatrix).id) == "old")
        #expect(try secrets.secret(for: "admin-password") == nil)
    }

    @Test func aLegacyFileWithoutAHostHasNoMatrices() throws {
        let (core, _, _) = try makeCore(file: #"{"matrix":{"port":80}}"#)
        #expect(core.matrices.isEmpty)
        #expect(core.phase == .notConfigured)
    }

    @Test func severalMatricesSurviveASaveAndLoad() throws {
        var settings = AppSettings()
        let a = MatrixProfile(name: "Lounge", config: MatrixConfig(host: "10.0.0.1"))
        let b = MatrixProfile(name: "", config: MatrixConfig(host: "10.0.0.2", port: 8080))
        settings.matrices = [a, b]
        settings.selectedMatrixID = b.id
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p8m-\(UUID().uuidString).json")
        try settings.save(to: url)

        let loaded = AppSettings.load(from: url)
        #expect(loaded == settings)
        #expect(loaded.selectedMatrix == b)
        #expect(loaded.matrix.port == 8080)
    }

    @Test func oneUnreadableMatrixDoesNotLoseTheOthers() throws {
        let good = #"{"id":"\#(UUID().uuidString)","name":"Good","host":"10.0.0.1"}"#
        let (core, _, _) = try makeCore(file: #"{"matrices":[\#(good),"nonsense",{"host":"10.0.0.3"}]}"#)
        #expect(core.matrices.map(\.config.host) == ["10.0.0.1", "10.0.0.3"])
    }

    @Test func aSelectionThatNamesNothingFallsBackToTheFirstMatrix() throws {
        let (core, _, _) = try makeCore(file: #"{"matrices":[{"host":"10.0.0.1"},{"host":"10.0.0.2"}],"selectedMatrix":"\#(UUID().uuidString)"}"#)
        #expect(core.selectedMatrix?.config.host == "10.0.0.1")
    }

    // MARK: Saving

    @Test func theFirstMatrixAddedIsSelectedAndLaterOnesAreNot() throws {
        let (core, _, url) = try makeCore()
        let first = try core.saveMatrix(MatrixInput(name: "Lounge", host: " 10.0.0.1 "))
        let second = try core.saveMatrix(MatrixInput(name: "Cinema", host: "10.0.0.2", port: "8080"))

        #expect(core.matrices.map(\.id) == [first, second])
        #expect(core.selectedMatrix?.id == first)
        #expect(core.matrices[0].config.host == "10.0.0.1")
        #expect(core.matrices[1].config.port == 8080)
        #expect(AppSettings.load(from: url).matrices.map(\.name) == ["Lounge", "Cinema"])
    }

    @Test func editingChangesThatMatrixOnly() throws {
        let (core, _, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(name: "A", host: "10.0.0.1"))
        let b = try core.saveMatrix(MatrixInput(name: "B", host: "10.0.0.2"))
        try core.saveMatrix(MatrixInput(id: b, name: "B2", host: "10.0.0.22", timeout: "4"))

        #expect(core.matrices.map(\.name) == ["A", "B2"])
        #expect(core.matrices[1].config.host == "10.0.0.22")
        #expect(core.matrices[1].config.timeout == 4)
        #expect(core.matrices[0].config.host == "10.0.0.1")
        #expect(core.selectedMatrix?.id == a)
    }

    @Test func aBlankNameShowsTheAddress() throws {
        let (core, _, _) = try makeCore()
        try core.saveMatrix(MatrixInput(name: "   ", host: "10.0.0.1", port: "8080"))
        #expect(core.selectedMatrix?.name == "")
        #expect(core.selectedMatrix?.displayName == "10.0.0.1:8080")
        #expect(core.hostLabel == "10.0.0.1:8080")
    }

    @Test func theNameIsWhatTheConnectionIsCalled() throws {
        let (core, _, _) = try makeCore()
        try core.saveMatrix(MatrixInput(name: "Lounge", host: "10.0.0.1"))
        #expect(core.hostLabel == "Lounge")
    }

    @Test func invalidInputIsRefusedAndNothingIsSaved() throws {
        let (core, _, url) = try makeCore()
        for input in [
            MatrixInput(host: " "), MatrixInput(host: "h", port: "0"), MatrixInput(host: "h", timeout: "0"),
            MatrixInput(host: "h", pollInterval: "x"), MatrixInput(host: "h", detailPollInterval: "-1"),
        ] {
            #expect(throws: CoreError.self) { try core.saveMatrix(input) }
        }
        #expect(core.matrices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func editingAMatrixThatIsGoneIsRefused() throws {
        let (core, _, _) = try makeCore()
        #expect(throws: CoreError.invalid("That matrix is no longer in the list.")) {
            try core.saveMatrix(MatrixInput(id: UUID(), host: "10.0.0.1"))
        }
    }

    // MARK: Passwords

    @Test func eachMatrixKeepsItsOwnAdminPassword() throws {
        let (core, secrets, url) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(host: "10.0.0.1", adminPassword: "alpha"))
        let b = try core.saveMatrix(MatrixInput(host: "10.0.0.2", adminPassword: "beta"))

        #expect(try password(secrets, a) == "alpha")
        #expect(try password(secrets, b) == "beta")
        #expect(core.hasAdminPassword(for: a) && core.hasAdminPassword(for: b))
        // Never in the settings file.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("alpha") && !text.contains("beta"))
    }

    @Test func aBlankPasswordKeepsTheSavedOneAndClearingForgetsIt() throws {
        let (core, secrets, _) = try makeCore()
        let id = try core.saveMatrix(MatrixInput(host: "10.0.0.1", adminPassword: "pw"))
        try core.saveMatrix(MatrixInput(id: id, host: "10.0.0.1", adminPassword: ""))
        #expect(try password(secrets, id) == "pw")

        try core.saveMatrix(MatrixInput(id: id, host: "10.0.0.1", clearAdminPassword: true))
        #expect(try password(secrets, id) == nil)
        #expect(!core.hasAdminPassword(for: id))
    }

    // MARK: Selecting and removing

    @Test func selectingAnotherMatrixSwitchesAndPersists() async throws {
        let (core, _, url) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(name: "A", host: "10.0.0.1"))
        let b = try core.saveMatrix(MatrixInput(name: "B", host: "10.0.0.2", port: "81"))
        #expect(core.selectedMatrix?.id == a)

        try core.selectMatrix(id: b)
        #expect(core.selectedMatrix?.id == b)
        #expect(core.settings.matrix.port == 81)
        #expect(AppSettings.load(from: url).selectedMatrix?.id == b)
        #expect(core.phase == .connecting)
    }

    @Test func selectingASwitchedToMatrixWaitsForItsOwnConnection() async throws {
        let (core, _, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(host: "10.0.0.1", timeout: "3", pollInterval: "1", detailPollInterval: "1"))
        let b = try core.saveMatrix(MatrixInput(host: "10.0.0.2", timeout: "3", pollInterval: "1", detailPollInterval: "1"))
        await core.start()
        for _ in 0..<250 where core.phase != .connected { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(core.phase == .connected)
        #expect(core.state != nil)

        try core.selectMatrix(id: b)
        #expect(core.state == nil, "nothing of the previous matrix is shown while this one connects")
        for _ in 0..<250 where core.phase != .connected { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(core.phase == .connected)
        #expect(core.selectedMatrix?.id != a)
        await core.stop()
    }

    @Test func removingTheSelectedMatrixSelectsTheFirstRemaining() throws {
        let (core, secrets, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(host: "10.0.0.1"))
        let b = try core.saveMatrix(MatrixInput(host: "10.0.0.2", adminPassword: "pw"))
        let c = try core.saveMatrix(MatrixInput(host: "10.0.0.3"))
        try core.selectMatrix(id: b)

        try core.removeMatrix(id: b)
        #expect(core.matrices.map(\.id) == [a, c])
        #expect(core.selectedMatrix?.id == a)
        #expect(try password(secrets, b) == nil, "its password goes with it")
    }

    @Test func removingTheLastMatrixLeavesTheAppNotConfigured() throws {
        let (core, _, _) = try makeCore()
        let only = try core.saveMatrix(MatrixInput(host: "10.0.0.1"))
        try core.removeMatrix(id: only)
        #expect(core.matrices.isEmpty)
        #expect(core.selectedMatrix == nil)
        #expect(core.phase == .notConfigured)
    }

    @Test func removingAnotherMatrixKeepsTheSelection() throws {
        let (core, _, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(host: "10.0.0.1"))
        let b = try core.saveMatrix(MatrixInput(host: "10.0.0.2"))
        try core.removeMatrix(id: b)
        #expect(core.selectedMatrix?.id == a)
    }

    @Test func selectingOrRemovingAnUnknownMatrixIsRefused() throws {
        let (core, _, _) = try makeCore()
        try core.saveMatrix(MatrixInput(host: "10.0.0.1"))
        #expect(throws: CoreError.self) { try core.selectMatrix(id: UUID()) }
        #expect(throws: CoreError.self) { try core.removeMatrix(id: UUID()) }
        #expect(core.matrices.count == 1)
    }

    // MARK: The older single-matrix calls

    @Test func saveSettingsChangesTheSelectedMatrixAndKeepsItsName() throws {
        let (core, secrets, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(name: "Lounge", host: "10.0.0.1"))
        try core.saveMatrix(MatrixInput(name: "Cinema", host: "10.0.0.2"))
        try core.saveSettings(SettingsInput(host: "10.0.0.11", adminPassword: "pw"))

        #expect(core.matrices[0].name == "Lounge")
        #expect(core.matrices[0].config.host == "10.0.0.11")
        #expect(core.matrices[1].config.host == "10.0.0.2")
        #expect(try password(secrets, a) == "pw")

        try core.removeAdminPassword()
        #expect(try password(secrets, a) == nil)
    }

    // MARK: JSON and snapshot

    @Test func theJSONCommandsAddSelectAndRemove() async throws {
        let (core, _, _) = try makeCore()
        let added = try JSONSerialization.jsonObject(with: Data(await core.handle(requestJSON:
            #"{"cmd":"saveMatrix","name":"Lounge","host":"10.0.0.1","adminPassword":"pw"}"#).utf8)) as? [String: Any]
        let first = try #require(added?["value"] as? String)
        #expect(added?["ok"] as? Bool == true)
        #expect(UUID(uuidString: first) != nil)

        let second = try #require((try JSONSerialization.jsonObject(with: Data(await core.handle(requestJSON:
            #"{"cmd":"saveMatrix","name":"Cinema","host":"10.0.0.2"}"#).utf8)) as? [String: Any])?["value"] as? String)
        #expect(core.matrices.count == 2)

        #expect(await core.handle(requestJSON: #"{"cmd":"selectMatrix","id":"\#(second)"}"#) == #"{"ok":true}"#)
        #expect(core.selectedMatrix?.name == "Cinema")

        #expect(await core.handle(requestJSON: #"{"cmd":"saveMatrix","id":"\#(first)","name":"Den","host":"10.0.0.1"}"#).contains(#""ok":true"#))
        #expect(core.matrices[0].name == "Den")

        #expect(await core.handle(requestJSON: #"{"cmd":"removeMatrix","id":"\#(second)"}"#) == #"{"ok":true}"#)
        #expect(core.matrices.map(\.name) == ["Den"])

        #expect(await core.handle(requestJSON: #"{"cmd":"selectMatrix","id":"not-an-id"}"#).contains(#""ok":false"#))
        #expect(await core.handle(requestJSON: #"{"cmd":"selectMatrix"}"#).contains(#""ok":false"#))
    }

    @Test func theSnapshotListsTheMatricesWithoutPasswords() throws {
        let (core, _, _) = try makeCore()
        let a = try core.saveMatrix(MatrixInput(name: "Lounge", host: "10.0.0.1", adminPassword: "hunter2"))
        let b = try core.saveMatrix(MatrixInput(host: "10.0.0.2", port: "8080"))

        let snapshot = CoreSnapshot(core: core)
        #expect(snapshot.matrices.map(\.id) == [a.uuidString.lowercased(), b.uuidString.lowercased()])
        #expect(snapshot.matrices.map(\.displayName) == ["Lounge", "10.0.0.2:8080"])
        #expect(snapshot.matrices.map(\.selected) == [true, false])
        #expect(snapshot.matrices.map(\.adminPasswordSaved) == [true, false])
        #expect(snapshot.settings.host == "10.0.0.1")
        #expect(!snapshot.jsonString().contains("hunter2"))
    }
}
