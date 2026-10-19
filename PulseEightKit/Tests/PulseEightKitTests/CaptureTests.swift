import Foundation
import Testing
@testable import PulseEightKit

@Suite struct CaptureTests {
    func makeClient(_ transport: MockTransport) throws -> MatrixClient {
        try MatrixClient(host: "10.0.0.5", transport: transport)
    }

    @Test func capturesEveryEndpointAndEveryPort() async throws {
        let result = try await DeviceCapture.capture(from: makeClient(.device()))

        #expect(result.skipped.isEmpty)
        #expect(result.files.map(\.name) == [
            "system-details.json", "system-features.json", "system-health.json", "monitoring-settings.json", "port-list.json",
            "port-details-input-0.json", "port-details-input-1.json",
            "port-details-output-0.json", "port-details-output-1.json",
        ])
    }

    @Test func capturedFilesDecodeWithTheModels() async throws {
        let result = try await DeviceCapture.capture(from: makeClient(.device()))
        func data(_ name: String) throws -> Data {
            try #require(result.files.first { $0.name == name }).data
        }
        let decoder = JSONDecoder()

        #expect(try decoder.decode(SystemDetails.self, from: data("system-details.json")).model == "NeoMatrix")
        #expect(try decoder.decode(SystemFeatures.self, from: data("system-features.json")).hdbaset)
        #expect(try decoder.decode(SystemHealth.self, from: data("system-health.json")).uptime == 899)
        #expect(try decoder.decode(MonitoringSettings.self, from: data("monitoring-settings.json")).lastContact == 1213)
        #expect(try decoder.decode(PortListResponse.self, from: data("port-list.json")).ports.count == 4)
        #expect(try decoder.decode(InputPortDetails.self, from: data("port-details-input-0.json")).base.bay == 0)
        #expect(try decoder.decode(OutputPortDetails.self, from: data("port-details-output-1.json")).base.mode == .output)
    }

    @Test func redactsSerialAndMACButNothingElse() async throws {
        let result = try await DeviceCapture.capture(from: makeClient(.device()))
        let details = try #require(result.files.first { $0.name == "system-details.json" })
        let text = String(decoding: details.data, as: UTF8.self)

        #expect(text.contains(#""Serial":"REDACTED""#))
        #expect(text.contains(#""MAC":"REDACTED""#))
        #expect(!text.contains("ABC123"))
        #expect(!text.contains("00:11:22:33:44:55"))
        // Everything else is untouched and the file still decodes.
        #expect(text.contains(#""Model":"NeoMatrix""#))
        #expect(try JSONDecoder().decode(SystemDetails.self, from: details.data).serial == "REDACTED")
    }

    @Test func noRedactKeepsTheDevicesBytesExactly() async throws {
        let result = try await DeviceCapture.capture(from: makeClient(.device()), redact: false)
        let details = try #require(result.files.first { $0.name == "system-details.json" })
        #expect(details.data == Data(Fixtures.systemDetails.utf8))
    }

    @Test func redactionHandlesNumbersSpacingAndEscapedQuotes() {
        let original = #"{"Serial" : 1234567, "Other":1.0, "MAC":"a\"b", "Keep": "Serial"}"#
        let redacted = String(decoding: DeviceCapture.redact(Data(original.utf8)), as: UTF8.self)

        // Numbers become 0, strings become "REDACTED"; spacing, 1.0 and unrelated strings are preserved.
        #expect(redacted == #"{"Serial" : 0, "Other":1.0, "MAC":"REDACTED", "Keep": "Serial"}"#)
    }

    @Test func aPortTheDeviceRefusesIsSkippedNotFatal() async throws {
        let transport = MockTransport { request in
            if request.url.path == "/Port/Details/Output/1" { return MockTransport.reply(#"{"Result":false,"Message":"Busy"}"#) }
            return MockTransport.device().handlerResponse(for: request)
        }
        let result = try await DeviceCapture.capture(from: makeClient(transport))

        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.contains("Output 1") == true)
        #expect(result.files.contains { $0.name == "port-details-output-0.json" })
        #expect(!result.files.contains { $0.name == "port-details-output-1.json" })
    }

    @Test func aFailingListIsFatal() async throws {
        let transport = MockTransport { request in
            request.url.path == "/Port/List" ? MockTransport.reply("", status: 500) : MockTransport.device().handlerResponse(for: request)
        }
        await #expect(throws: MatrixError.api("API returned status 500")) {
            _ = try await DeviceCapture.capture(from: makeClient(transport))
        }
    }
}

@Suite struct CaptureRedactionAndGapsTests {
    @Test func theInstallerIdIsRedactedLikeTheSerialAndMAC() async throws {
        let result = try await DeviceCapture.capture(from: MatrixClient(host: "10.0.0.5", transport: MockTransport.device()))
        let text = String(decoding: try #require(result.files.first { $0.name == "monitoring-settings.json" }).data, as: UTF8.self)
        #expect(text.contains(#""InstallerId":0"#))
        #expect(!text.contains("1924"))
        #expect(text.contains(#""LastContact":1213"#), "everything else is kept exactly as the matrix sent it")

        let raw = try await DeviceCapture.capture(from: MatrixClient(host: "10.0.0.5", transport: MockTransport.device()), redact: false)
        #expect(String(decoding: try #require(raw.files.first { $0.name == "monitoring-settings.json" }).data, as: UTF8.self).contains("1924"))
    }

    @Test func aMatrixWithoutTheCloudPageIsNotedAndTheRestIsCaptured() async throws {
        let device = MockTransport.device()
        let transport = MockTransport { request in
            request.url.path == "/Monitoring/Settings" ? MockTransport.reply("", status: 404) : device.handlerResponse(for: request)
        }
        let result = try await DeviceCapture.capture(from: MatrixClient(host: "10.0.0.5", transport: transport))
        #expect(!result.files.map(\.name).contains("monitoring-settings.json"))
        #expect(result.skipped.contains { $0.contains("Monitoring/Settings") })
        #expect(result.files.count == 8)
    }
}

@Suite struct CaptureWithoutHealthTests {
    @Test func aMatrixWithoutAHealthPageIsNotedAndTheRestIsCaptured() async throws {
        let device = MockTransport.device()
        let transport = MockTransport { request in
            request.url.path == "/System/Health" ? MockTransport.reply("", status: 404) : device.handlerResponse(for: request)
        }
        let result = try await DeviceCapture.capture(from: MatrixClient(host: "10.0.0.5", transport: transport))

        #expect(!result.files.map(\.name).contains("system-health.json"))
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.contains("System/Health") == true)
        #expect(result.files.count == 8)
    }
}
