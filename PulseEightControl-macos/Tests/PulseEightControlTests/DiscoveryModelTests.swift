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
            settings.matrix = saved
            try? settings.save(to: url)
        }
        let core = AppCore(secrets: MemorySecrets(), settingsURL: url, makeTransport: { _ in ServiceTransport(response: response) })
        return (AppModel(core: core), url)
    }

    @Test func settingsFillsInTheFieldsButDoesNotSave() async {
        let (model, url) = makeModel(Self.found)
        await model.findMatrixForSettings()

        #expect(model.draft.host == "192.168.1.50")
        #expect(model.draft.port == "8080")
        #expect(model.settingsMessage?.isError == false)
        #expect(model.core.settings.matrix.host == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!model.discovering)
    }

    @Test func settingsExplainsWhenNothingWasFound() async {
        let (model, _) = makeModel(Self.none)
        model.draft.host = "10.0.0.9"
        await model.findMatrixForSettings()

        #expect(model.draft.host == "10.0.0.9", "a failed search leaves what was typed")
        #expect(model.settingsMessage?.isError == true)
        #expect(model.settingsMessage?.text.contains("No matrix found") == true)
    }

    @Test func settingsShowsAServiceFailure() async {
        let (model, _) = makeModel(.failure(TransportError("offline")))
        await model.findMatrixForSettings()
        #expect(model.settingsMessage?.text == "Couldn't reach gotomymatrix.com: offline")
    }

    @Test func connectionScreenSavesWhatWasFoundAndKeepsOtherSettings() async {
        let (model, url) = makeModel(Self.found)
        await model.findAndConnect()

        #expect(model.discoveryError == nil)
        #expect(model.core.settings.matrix.host == "192.168.1.50")
        #expect(model.core.settings.matrix.port == 8080)
        #expect(AppSettings.load(from: url).matrix.host == "192.168.1.50")
    }

    @Test func connectionScreenKeepsTheOtherSavedSettings() async {
        let saved = MatrixConfig(host: "10.0.0.1", port: 80, timeout: 7, pollInterval: 3, detailPollInterval: 30)
        let (model, _) = makeModel(Self.found, saved: saved)
        await model.findAndConnect()

        let matrix = model.core.settings.matrix
        #expect(matrix.host == "192.168.1.50")
        #expect(matrix.timeout == 7)
        #expect(matrix.pollInterval == 3)
        #expect(matrix.detailPollInterval == 30)
    }

    @Test func connectionScreenReportsNothingFoundAndSavesNothing() async {
        let (model, url) = makeModel(Self.none)
        await model.findAndConnect()

        #expect(model.discoveryError?.contains("No matrix found") == true)
        #expect(model.core.settings.matrix.host == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
