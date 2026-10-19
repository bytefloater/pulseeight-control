import Foundation
import Testing
import PulseEightCore
import PulseEightKit
@testable import PulseEightControl

/// Plays the discovery service: a LAN redirect for gotomymatrix.com, a dead end for anything else.
private struct ServiceTransport: HTTPTransport {
    var response: Result<HTTPResponse, TransportError>
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host == "gotomymatrix.com" else { throw TransportError("connection refused") }
        return try response.get()
    }
}

@MainActor
@Suite struct DiscoveryModelTests {
    static let found = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 302, body: Data(), location: "http://192.168.1.50:8080/"))
    static let none = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 200, body: Data()))

    func makeModel(_ response: Result<HTTPResponse, TransportError>, saved: MatrixConfig? = nil) -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8discover-\(UUID().uuidString)").appendingPathComponent("settings.json")
        if let saved {
            var settings = AppSettings()
            settings.matrices = [MatrixProfile(config: saved)]
            try? settings.save(to: url)
        }
        let core = AppCore(secrets: MemorySecrets(), settingsURL: url, makeTransport: { _ in ServiceTransport(response: response) })
        return (AppModel(core: core, localNetwork: .disabled), url)
    }

    @Test func theEditorFillsInTheFieldsButDoesNotSave() async {
        let (model, url) = makeModel(Self.found)
        model.beginEditingMatrix(nil)
        await model.findMatrixForDraft()

        #expect(model.matrixDraft.host == "192.168.1.50")
        #expect(model.matrixDraft.port == "8080")
        #expect(model.matrixMessage?.isError == false)
        #expect(model.core.matrices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!model.discovering)
    }

    @Test func theEditorExplainsWhenNothingWasFound() async {
        let (model, _) = makeModel(Self.none)
        model.beginEditingMatrix(nil)
        model.matrixDraft.host = "10.0.0.9"
        await model.findMatrixForDraft()

        #expect(model.matrixDraft.host == "10.0.0.9", "a failed search leaves what was typed")
        #expect(model.matrixMessage?.isError == true)
        #expect(model.matrixMessage?.text.contains("No matrix found") == true)
    }

    @Test func theEditorShowsAServiceFailure() async {
        let (model, _) = makeModel(.failure(TransportError("offline")))
        await model.findMatrixForDraft()
        #expect(model.matrixMessage?.text == "Couldn't reach gotomymatrix.com: offline")
    }

    @Test func connectionScreenAddsAndSelectsWhatWasFound() async {
        let (model, url) = makeModel(Self.found)
        await model.findAndConnect()

        #expect(model.discoveryError == nil)
        #expect(model.core.settings.matrix.host == "192.168.1.50")
        #expect(model.core.settings.matrix.port == 8080)
        #expect(AppSettings.load(from: url).matrix.host == "192.168.1.50")
    }

    @Test func connectionScreenAddsAnotherMatrixAndKeepsTheFirstOneAsItWas() async {
        let saved = MatrixConfig(host: "10.0.0.1", port: 80, timeout: 7, pollInterval: 3, detailPollInterval: 30)
        let (model, _) = makeModel(Self.found, saved: saved)
        await model.findAndConnect()

        #expect(model.core.matrices.count == 2)
        #expect(model.core.matrices[0].config == saved)
        #expect(model.core.selectedMatrix?.config.host == "192.168.1.50")
    }

    @Test func connectionScreenShowsAnAlreadyConfiguredMatrixInsteadOfAddingItAgain() async {
        let saved = MatrixConfig(host: "192.168.1.50", port: 8080)
        let (model, _) = makeModel(Self.found, saved: saved)
        await model.findAndConnect()

        #expect(model.core.matrices.count == 1)
        #expect(model.discoveryError == nil)
    }

    @Test func connectionScreenReportsNothingFoundAndSavesNothing() async {
        let (model, url) = makeModel(Self.none)
        await model.findAndConnect()

        #expect(model.discoveryError?.contains("No matrix found") == true)
        #expect(model.core.settings.matrix.host == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
