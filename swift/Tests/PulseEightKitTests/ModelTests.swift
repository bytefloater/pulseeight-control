import Foundation
import Testing
@testable import PulseEightKit

@Suite struct ModelTests {
    func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesPortList() throws {
        let response = try decode(Fixtures.portList, as: PortListResponse.self)
        #expect(response.ports.count == 4)
        let bedroom = try #require(response.ports.last)
        #expect(bedroom.mode == .output)
        #expect(bedroom.name == "Bedroom TV")
        #expect(bedroom.status == .warning)
        #expect(bedroom.receiveFrom == 1)
        #expect(bedroom.rcType == 2)
        #expect(response.ports[0].receiveFrom == nil)
    }

    @Test func unknownStatusCodeFallsBackToNotPresent() throws {
        let port = try decode(#"{"Bay":0,"Mode":"Input","Type":"x","Status":99,"Name":"n"}"#, as: MatrixPort.self)
        #expect(port.status == .moduleNotPresent)
    }

    /// Regression for backend/app/pulse8_service.py `_apply_raw_feature_corrections`: the Python
    /// library read these three fields from wrongly-cased keys and always got None.
    @Test func featuresReadAllCapsAcronyms() throws {
        let features = try decode(Fixtures.systemFeatures, as: SystemFeatures.self)
        #expect(features.backlightLED == "High")
        #expect(features.backlight == .high)
        #expect(features.statusLEDOn == true)
        #expect(features.cec == true)  // sent as 1, accepted like pydantic's lax bool
        #expect(features.video.scrambling)
        #expect(features.video.input["Bays"]?.intValue == 8)
    }

    @Test func featuresTolerateMissingOptionals() throws {
        let json = Fixtures.systemFeatures
            .replacingOccurrences(of: #""CEC":1,"#, with: "")
            .replacingOccurrences(of: #""BacklightLED":"High","StatusLED":"On""#, with: #""Other":0"#)
        let features = try decode(json, as: SystemFeatures.self)
        #expect(features.cec == nil)
        #expect(features.backlight == nil)
        #expect(features.statusLEDOn == nil)
    }

    @Test func decodesSystemDetails() throws {
        let details = try decode(Fixtures.systemDetails, as: SystemDetails.self)
        #expect(details.model == "NeoMatrix")
        #expect(details.mac == "00:11:22:33:44:55")
        #expect(details.revision.ir == 3)
    }

    @Test func decodesInputDetails() throws {
        let details = try decode(Fixtures.inputDetails, as: InputPortDetails.self)
        #expect(details.base.hasSignal == true)
        #expect(details.base.videoSignal == "3840x2160@60")
        #expect(details.hdcp == 1)
        #expect(details.edidProfile == 0)
    }

    @Test func decodesOutputDetails() throws {
        let details = try decode(Fixtures.outputDetails, as: OutputPortDetails.self)
        #expect(details.firmwareVersionAvailable == true)
        #expect(details.poe == true)
        #expect(details.overrideEDID?.setting == 3)
        #expect(details.linkQuality == nil)
        #expect(details.base.name == "Lounge TV")
    }

    @Test func statusDescriptionMatchesPythonModel() throws {
        func base(status: Int, type: String = "HDMI IN", mode: String = "Input") throws -> BasePortDetails {
            try decode(#"{"Result":true,"Bay":0,"Mode":"\#(mode)","Type":"\#(type)","Status":\#(status),"Name":"n","StatusMessage":"msg"}"#)
        }
        #expect(try base(status: 3).statusDescription == "No HDMI Signal")
        #expect(try base(status: 3, type: "AUDIO IN").statusDescription == "Audio Only")
        #expect(try base(status: 4).statusDescription == "Input Not Present")
        #expect(try base(status: 1, mode: "Output").statusDescription == "Output is Faulty")
        #expect(try base(status: 0).statusDescription == "OK")
    }

    @Test func configImportsLegacyConfigJSON() throws {
        let config = try decode(
            #"{"host":"192.168.1.150","port":80,"timeout":10,"poll_interval":5,"detail_poll_interval":20,"admin_password":null}"#,
            as: MatrixConfig.self
        )
        #expect(config == MatrixConfig(host: "192.168.1.150"))
        #expect(try decode("{}", as: MatrixConfig.self) == MatrixConfig())
    }
}

@Suite struct EdidProfileTests {
    let outputs = [
        MatrixPort(bay: 1, mode: .output, type: "", status: .ok, name: "Bedroom"),
        MatrixPort(bay: 0, mode: .output, type: "", status: .ok, name: "Lounge"),
        MatrixPort(bay: 0, mode: .input, type: "", status: .ok, name: "Sky"),
    ]

    @Test func hdrProfilesNeedScrambling() {
        #expect(EdidProfiles.build(scrambling: false, ports: []).map(\.id) == [11, 4, 0, 3, 5, 2, 6])
        #expect(EdidProfiles.build(scrambling: true, ports: []).map(\.id) == [11, 4, 0, 3, 5, 2, 6, 7, 8])
    }

    @Test func cloneProfilesCoverOutputsOnlyInBayOrder() {
        let clones = EdidProfiles.build(scrambling: false, ports: outputs).suffix(2)
        #expect(clones.map(\.id) == [101, 102])
        #expect(clones.map(\.name) == ["Clone Display 1 — Lounge", "Clone Display 2 — Bedroom"])
    }
}
