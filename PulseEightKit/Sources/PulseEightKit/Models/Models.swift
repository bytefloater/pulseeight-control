import Foundation

// Ported from pulse_eight_matrix_client/models.py (0.5.0). That library used a pydantic
// alias generator that capitalizes each snake_case word, so the wire keys are spelled out here.
// Where it got an acronym wrong (BacklightLED, StatusLED, CEC), the keys below are the
// device's real ones, so legacy/PulseEightWeb/backend/app/pulse8_service.py's _apply_raw_feature_corrections is not needed.

public enum PortMode: String, Decodable, Sendable, Hashable, CaseIterable {
    case input = "Input"
    case output = "Output"
}

public enum PortStatus: Int, Decodable, Sendable, Hashable {
    case ok = 0
    case moduleFault = 1
    case warning = 2
    case noSignal = 3
    case moduleNotPresent = 4

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        // Same fallback the web UI used for codes it didn't know (app.js STATUS_CLASS lookup).
        self = PortStatus(rawValue: raw) ?? .moduleNotPresent
    }

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .moduleFault: return "Module fault"
        case .warning: return "Warning"
        case .noSignal: return "No signal"
        case .moduleNotPresent: return "Not present"
        }
    }
}

public struct MatrixPort: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public var bay: Int
    public var mode: PortMode
    public var type: String
    public var status: PortStatus
    public var name: String
    public var receiveFrom: Int?
    public var rcType: Int?

    public var id: String { "\(mode.rawValue):\(bay)" }

    enum CodingKeys: String, CodingKey {
        case bay = "Bay", mode = "Mode", type = "Type", status = "Status", name = "Name"
        case receiveFrom = "ReceiveFrom", rcType
    }

    public init(bay: Int, mode: PortMode, type: String, status: PortStatus, name: String, receiveFrom: Int? = nil, rcType: Int? = nil) {
        self.bay = bay
        self.mode = mode
        self.type = type
        self.status = status
        self.name = name
        self.receiveFrom = receiveFrom
        self.rcType = rcType
    }
}

struct PortListResponse: Decodable {
    var ports: [MatrixPort]

    enum CodingKeys: String, CodingKey { case ports = "Ports" }
}

public struct SetPortResponse: Decodable, Sendable, Equatable {
    @LenientBool public var result: Bool
    public var message: String

    enum CodingKeys: String, CodingKey { case result = "Result", message = "Message" }
}

// MARK: - System

public struct Revision: Decodable, Sendable, Equatable {
    public var main: Int
    public var top: Int
    public var ir: Int

    enum CodingKeys: String, CodingKey { case main = "Main", top = "Top", ir = "Ir" }
}

public struct SystemDetails: Decodable, Sendable, Equatable {
    @LenientBool public var result: Bool
    public var model: String
    public var version: String
    public var serial: String
    public var mac: String
    public var vid: String
    public var boardRev: Int
    public var revision: Revision
    public var locale: String
    public var statusMessage: String
    public var status: Int

    enum CodingKeys: String, CodingKey {
        case result = "Result", model = "Model", version = "Version", serial = "Serial"
        case mac = "MAC", vid = "VID", boardRev = "BoardRev", revision = "Revision"
        case locale = "Locale", statusMessage = "StatusMessage", status = "Status"
    }
}

public struct VideoFeatures: Decodable, Sendable, Equatable {
    @LenientBool public var scrambling: Bool
    public var ir: [String: JSONValue]?
    public var input: [String: JSONValue]
    public var output: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case scrambling = "Scrambling", ir = "Ir", input = "Input", output = "Output"
    }
}

public struct AudioFeatures: Decodable, Sendable, Equatable {
    public var arc: [String: JSONValue]?
    @LenientBool public var routing: Bool
    @LenientOptionalBool public var dsp: Bool?
    public var input: [String: JSONValue]
    public var output: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case arc = "Arc", routing = "Routing", dsp = "Dsp", input = "Input", output = "Output"
    }
}

public enum BacklightLevel: String, Sendable, CaseIterable {
    case off, low, high
}

public struct SystemFeatures: Decodable, Sendable, Equatable {
    @LenientBool public var result: Bool
    public var updInterval: Int
    @LenientOptionalBool public var cec: Bool?
    @LenientBool public var cecSwitching: Bool
    public var cecLogging: Int
    public var cecUsage: Int
    @LenientBool public var pdu: Bool
    @LenientBool public var sky: Bool
    @LenientBool public var hdbaset: Bool
    @LenientBool public var hdbtUpgrade: Bool
    @LenientBool public var mxRemote: Bool
    public var video: VideoFeatures
    public var audio: AudioFeatures
    /// Raw device value, e.g. "High". Use `backlight` for the typed form.
    public var backlightLED: String?
    public var statusLED: String?

    enum CodingKeys: String, CodingKey {
        case result = "Result", updInterval = "UpdInterval", cec = "CEC"
        case cecSwitching = "CEC_Switching", cecLogging = "CEC_Logging", cecUsage = "CEC_Usage"
        case pdu = "PDU", sky = "Sky", hdbaset = "HDBaseT", hdbtUpgrade = "HdbtUpgrade", mxRemote = "MxRemote"
        case video = "Video", audio = "Audio", backlightLED = "BacklightLED", statusLED = "StatusLED"
    }

    public var backlight: BacklightLevel? {
        backlightLED.flatMap { BacklightLevel(rawValue: $0.lowercased()) }
    }

    /// nil when the device didn't report it.
    public var statusLEDOn: Bool? {
        guard let value = statusLED?.lowercased() else { return nil }
        return value == "on"
    }
}

public struct SystemInfo: Sendable, Equatable {
    public var details: SystemDetails
    public var features: SystemFeatures

    public init(details: SystemDetails, features: SystemFeatures) {
        self.details = details
        self.features = features
    }
}

// MARK: - Port details

public struct OverrideEDIDDetails: Decodable, Sendable, Equatable {
    public var address: String
    public var setting: Int

    enum CodingKeys: String, CodingKey { case address = "Address", setting = "Setting" }
}

public struct LinkQualityDetails: Decodable, Sendable, Equatable {
    public var channelA: Double
    public var channelB: Double
    public var channelC: Double
    public var channelD: Double
    public var errorsChannelA: Double
    public var errorsChannelB: Double
    public var errorsChannelC: Double
    public var errorsChannelD: Double
    public var status: Int
    public var tmds: Int
    public var ber: Int
    public var totalBER: Int
    public var errorsControl: Int?
    public var errorsCRC: Int?
    public var errorsData: Int?
    public var errorsTMDS: Int?
    public var errorsVideo: Int?

    enum CodingKeys: String, CodingKey {
        case channelA = "ChannelA", channelB = "ChannelB", channelC = "ChannelC", channelD = "ChannelD"
        case errorsChannelA = "ErrorsChannelA", errorsChannelB = "ErrorsChannelB"
        case errorsChannelC = "ErrorsChannelC", errorsChannelD = "ErrorsChannelD"
        case status = "Status", tmds = "TMDS", ber = "BER", totalBER = "TotalBER"
        case errorsControl = "ErrorsControl", errorsCRC = "ErrorsCRC", errorsData = "ErrorsData"
        case errorsTMDS = "ErrorsTMDS", errorsVideo = "ErrorsVideo"
    }
}

/// Fields shared by input and output details. Both detail types embed this.
public struct BasePortDetails: Decodable, Sendable, Equatable {
    @LenientBool public var result: Bool
    public var bay: Int
    public var mode: PortMode
    public var type: String
    public var status: PortStatus
    public var name: String
    public var statusMessage: String
    public var hpd: Int?
    @LenientOptionalBool public var hasSignal: Bool?
    public var videoSignal: String?
    public var signal: String?

    enum CodingKeys: String, CodingKey {
        case result = "Result", bay = "Bay", mode = "Mode", type = "Type", status = "Status", name = "Name"
        case statusMessage = "StatusMessage", hpd = "HPD", hasSignal = "HasSignal"
        case videoSignal = "VideoSignal", signal = "Signal"
    }

    /// Human-readable status, matching the Python model's `status_description`.
    public var statusDescription: String {
        switch status {
        case .noSignal: return type == "AUDIO IN" ? "Audio Only" : "No HDMI Signal"
        case .moduleNotPresent: return "\(mode.rawValue) Not Present"
        case .moduleFault: return "\(mode.rawValue) is Faulty"
        case .ok: return "OK"
        case .warning: return "Warning"
        }
    }
}

public struct InputPortDetails: Decodable, Sendable, Equatable {
    public var base: BasePortDetails
    public var transmissionNodes: [Int]?
    public var hdcp: Int?
    public var remote: Int?
    public var remoteStatus: String?
    public var remoteOnline: Int?
    public var configRemote: Int?
    public var allowedSinks: [Int]?
    public var edidProfile: Int?

    enum CodingKeys: String, CodingKey {
        case transmissionNodes = "TransmissionNodes", hdcp = "HDCP", remote = "Remote"
        case remoteStatus = "RemoteStatus", remoteOnline = "RemoteOnline", configRemote = "ConfigRemote"
        case allowedSinks = "AllowedSinks", edidProfile = "EdidProfile"
    }

    public init(from decoder: Decoder) throws {
        base = try BasePortDetails(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transmissionNodes = try c.decodeIfPresent([Int].self, forKey: .transmissionNodes)
        hdcp = try c.decodeIfPresent(Int.self, forKey: .hdcp)
        remote = try c.decodeIfPresent(Int.self, forKey: .remote)
        remoteStatus = try c.decodeIfPresent(String.self, forKey: .remoteStatus)
        remoteOnline = try c.decodeIfPresent(Int.self, forKey: .remoteOnline)
        configRemote = try c.decodeIfPresent(Int.self, forKey: .configRemote)
        allowedSinks = try c.decodeIfPresent([Int].self, forKey: .allowedSinks)
        edidProfile = try c.decodeIfPresent(Int.self, forKey: .edidProfile)
    }
}

public struct OutputPortDetails: Decodable, Sendable, Equatable {
    public var base: BasePortDetails
    public var receiveFrom: Int?
    public var allowedSources: [Int]?
    public var sinkState: Int?
    public var linkStatus: String?
    public var poe: Bool?
    public var firmwareVersion: String?
    public var firmwareVersionAvailable: Bool?
    public var supportSB: Bool?
    public var hdbtVendor: Int?
    public var description: String?
    public var fwBank: Int?
    public var cecPassthrough: Bool?
    public var physicalAddress: String?
    public var vendor: String?
    public var model: Int?
    public var monitorName: String?
    public var serial: Int?
    public var manufactured: String?
    public var edidRead: Bool?
    public var overrideEDID: OverrideEDIDDetails?
    public var estimatedCableLength: Int?
    public var linkQuality: LinkQualityDetails?

    enum CodingKeys: String, CodingKey {
        case receiveFrom = "ReceiveFrom", allowedSources = "AllowedSources", sinkState = "SinkState"
        case linkStatus = "LinkStatus", poe = "POE", firmwareVersion = "FirmwareVersion"
        case firmwareVersionAvailable = "FirmwareVersionAvailable", supportSB = "SupportSb"
        case hdbtVendor = "HDBT_Vendor", description = "Description", fwBank = "FwBank"
        case cecPassthrough = "CecPassthrough", physicalAddress = "PhysicalAddress", vendor = "Vendor"
        case model = "Model", monitorName = "MonitorName", serial = "Serial", manufactured = "Manufactured"
        case edidRead = "EdidRead", overrideEDID = "OverrideEDID"
        case estimatedCableLength = "EstimatedCableLength", linkQuality = "LinkQuality"
    }

    public init(from decoder: Decoder) throws {
        base = try BasePortDetails(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiveFrom = try c.decodeIfPresent(Int.self, forKey: .receiveFrom)
        allowedSources = try c.decodeIfPresent([Int].self, forKey: .allowedSources)
        sinkState = try c.decodeIfPresent(Int.self, forKey: .sinkState)
        linkStatus = try c.decodeIfPresent(String.self, forKey: .linkStatus)
        poe = try c.decodeIfPresent(LenientBool.self, forKey: .poe)?.wrappedValue
        firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion)
        firmwareVersionAvailable = try c.decodeIfPresent(LenientBool.self, forKey: .firmwareVersionAvailable)?.wrappedValue
        supportSB = try c.decodeIfPresent(LenientBool.self, forKey: .supportSB)?.wrappedValue
        hdbtVendor = try c.decodeIfPresent(Int.self, forKey: .hdbtVendor)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        fwBank = try c.decodeIfPresent(Int.self, forKey: .fwBank)
        cecPassthrough = try c.decodeIfPresent(LenientBool.self, forKey: .cecPassthrough)?.wrappedValue
        physicalAddress = try c.decodeIfPresent(String.self, forKey: .physicalAddress)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        model = try c.decodeIfPresent(Int.self, forKey: .model)
        monitorName = try c.decodeIfPresent(String.self, forKey: .monitorName)
        serial = try c.decodeIfPresent(Int.self, forKey: .serial)
        manufactured = try c.decodeIfPresent(String.self, forKey: .manufactured)
        edidRead = try c.decodeIfPresent(LenientBool.self, forKey: .edidRead)?.wrappedValue
        overrideEDID = try c.decodeIfPresent(OverrideEDIDDetails.self, forKey: .overrideEDID)
        estimatedCableLength = try c.decodeIfPresent(Int.self, forKey: .estimatedCableLength)
        linkQuality = try c.decodeIfPresent(LinkQualityDetails.self, forKey: .linkQuality)
    }
}

/// Mirrors `PortUpdateInfo` from legacy/PulseEightWeb/backend/app/schemas.py.
public struct FirmwareUpdate: Sendable, Equatable, Identifiable {
    public var bay: Int
    public var name: String
    public var firmwareVersion: String?

    public var id: Int { bay }

    public init(bay: Int, name: String, firmwareVersion: String?) {
        self.bay = bay
        self.name = name
        self.firmwareVersion = firmwareVersion
    }
}
