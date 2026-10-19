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

    /// Regression for legacy/PulseEightWeb/backend/app/pulse8_service.py `_apply_raw_feature_corrections`: the Python
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

    /// What a real NeoMatrix (firmware 3.10.6) sends: lower-case `revision`, snake_case `hdbt_upgrade` and
    /// `mx_remote`, and `IR`, `ARC` and `DSP`. Decoding these as the vendor library's spellings failed, so
    /// none of the system information loaded.
    @Test func decodesTheSpellingsARealMatrixSends() throws {
        let details = try decode(
            #"{"Result":true,"Model":"FF88A","Version":"3.10.6-1","Serial":"S","MAC":"m","VID":"P8","BoardRev":1,"revision":{"main":1,"top":7,"ir":0},"Locale":"EN_UK","StatusMessage":"Healthy","Status":0}"#,
            as: SystemDetails.self)
        #expect(details.model == "FF88A")
        #expect(details.version == "3.10.6-1")
        #expect(details.revision == Revision(main: 1, top: 7, ir: 0))
        #expect(details.statusMessage == "Healthy")

        let features = try decode(
            #"{"UpdInterval":3600000,"CEC":true,"CEC_Switching":true,"CEC_Logging":0,"CEC_Usage":58,"PDU":false,"Sky":false,"HDBaseT":true,"hdbt_upgrade":false,"mx_remote":true,"Video":{"Scrambling":false,"IR":{"Learn":true},"Input":{"Bays":8},"Output":{"Bays":10}},"Audio":{"ARC":{"support":false},"Routing":false,"DSP":false,"Input":{"Bays":0},"Output":{"Bays":0}},"BacklightLED":"high","StatusLED":"on","Result":true}"#,
            as: SystemFeatures.self)
        #expect(features.mxRemote)
        #expect(!features.hdbtUpgrade)
        #expect(features.hdbaset)
        #expect(features.video.ir?["Learn"] == .bool(true))
        #expect(features.video.output["Bays"]?.intValue == 10)
        #expect(features.audio.arc?["support"] == .bool(false))
        #expect(features.audio.dsp == false)
        #expect(features.backlight == .high)
        #expect(features.statusLEDOn == true)
    }

    @Test func systemDetailsOnlyNeedAModel() throws {
        let details = try decode(#"{"Model":"X"}"#, as: SystemDetails.self)
        #expect(details.model == "X")
        #expect(details.revision == Revision())
        #expect(details.statusMessage == "")
        #expect(throws: DecodingError.self) { try decode(#"{"Version":"1"}"#, as: SystemDetails.self) }
    }

    @Test func aWronglyTypedFieldFallsBackInsteadOfHidingTheRest() throws {
        let features = try decode(#"{"UpdInterval":"soon","CEC_Usage":58,"Video":"nonsense","BacklightLED":"low"}"#, as: SystemFeatures.self)
        #expect(features.updInterval == 0)
        #expect(features.cecUsage == 58)
        #expect(features.video == VideoFeatures())
        #expect(features.backlight == .low)
    }

    @Test func decodesTheHealthReportOfARealMatrix() throws {
        let health = try decode(Fixtures.systemHealth, as: SystemHealth.self)
        #expect(health.status == 0)
        #expect(health.statusMessage == "Healthy")
        #expect(health.rails.map(\.name) == ["3.3V", "12V", "1V top"])
        #expect(health.rails[1].volts == 12.256533)
        #expect(health.rails.allSatisfy { $0.ok })
        #expect(health.temperatures == [32, 31, 36])
        #expect(health.updateState == 6)
        #expect(health.uptime == 899)
        #expect(health.components == [
            HealthComponent(kind: .powerSupply(1), status: 0, message: "Present & Healthy"),
            HealthComponent(kind: .inputModules, status: 0, message: "All Present & Healthy"),
            HealthComponent(kind: .outputModules, status: 0, message: "All Present & Healthy"),
        ])
    }

    @Test func healthCopesWithWhateverTheFirmwareReports() throws {
        // Two supplies (one faulty), sensors out of order, and nothing else.
        let health = try decode(
            #"{"Temperature10":50,"Temperature2":30,"PSU2":3,"PSU2Message":"Not present","PSU1":0,"PSU1Message":"OK","Status":1,"StatusMessage":"Fault","psu":[{"name":"5V","ok":false,"value":4.1}]}"#,
            as: SystemHealth.self)
        #expect(health.temperatures == [30, 50], "sensors are ordered by number, not by how they were sent")
        #expect(health.components.map(\.kind) == [.powerSupply(1), .powerSupply(2)])
        #expect(health.components.map(\.isHealthy) == [true, false])
        #expect(health.rails == [PowerRail(name: "5V", ok: false, volts: 4.1)])
        #expect(health.status == 1)
        #expect(health.uptime == nil && health.updateState == nil)

        let empty = try decode("{}", as: SystemHealth.self)
        #expect(empty.rails.isEmpty && empty.temperatures.isEmpty && empty.components.isEmpty)
    }

    @Test func decodesTheCloudLinkOfARealMatrix() throws {
        let monitoring = try decode(Fixtures.monitoringSettings, as: MonitoringSettings.self)
        #expect(monitoring.cloudConnected, "Result is whether the matrix is connected to the cloud")
        #expect(monitoring.lastContact == 1213)
        #expect(monitoring.installerID == "1924")
        #expect(monitoring.autoUpdates == true)
        #expect(monitoring.updateAvailable == false)
    }

    @Test func theCloudLinkCopesWithWhateverTheFirmwareSends() throws {
        let down = try decode(#"{"result":false,"lastcontact":99999,"installerId":"abc-1"}"#, as: MonitoringSettings.self)
        #expect(!down.cloudConnected)
        #expect(down.lastContact == 99999)
        #expect(down.installerID == "abc-1", "an id that isn't a number is kept as text")

        let bare = try decode("{}", as: MonitoringSettings.self)
        #expect(!bare.cloudConnected)
        #expect(bare.lastContact == nil && bare.installerID == nil && bare.autoUpdates == nil && bare.updateAvailable == nil)
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
