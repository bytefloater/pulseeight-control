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

    public init(main: Int = 0, top: Int = 0, ir: Int = 0) {
        self.main = main
        self.top = top
        self.ir = ir
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        main = object.value("main", default: 0)
        top = object.value("top", default: 0)
        ir = object.value("ir", default: 0)
    }
}

public struct SystemDetails: Decodable, Sendable, Equatable {
    public var result: Bool
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

    public init(
        result: Bool = true, model: String, version: String, serial: String = "", mac: String = "", vid: String = "",
        boardRev: Int = 0, revision: Revision = Revision(), locale: String = "", statusMessage: String = "", status: Int = 0
    ) {
        self.result = result
        self.model = model
        self.version = version
        self.serial = serial
        self.mac = mac
        self.vid = vid
        self.boardRev = boardRev
        self.revision = revision
        self.locale = locale
        self.statusMessage = statusMessage
        self.status = status
    }

    /// Fields are found by name whatever their case (see `LooseObject`). Only a model is required: without
    /// one this isn't a system details reply at all.
    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        guard let model: String = object.value("model") else {
            throw DecodingError.keyNotFound(
                LooseKey(stringValue: "Model")!, .init(codingPath: decoder.codingPath, debugDescription: "No Model in the system details"))
        }
        self.model = model
        result = object.bool("result", default: true)
        version = object.value("version", default: "")
        serial = object.value("serial", default: "")
        mac = object.value("mac", default: "")
        vid = object.value("vid", default: "")
        boardRev = object.value("boardRev", default: 0)
        revision = object.value("revision", default: Revision())
        locale = object.value("locale", default: "")
        statusMessage = object.value("statusMessage", default: "")
        status = object.value("status", default: 0)
    }
}

public struct VideoFeatures: Decodable, Sendable, Equatable {
    public var scrambling: Bool
    public var ir: [String: JSONValue]?
    public var input: [String: JSONValue]
    public var output: [String: JSONValue]

    public init(scrambling: Bool = false, ir: [String: JSONValue]? = nil, input: [String: JSONValue] = [:], output: [String: JSONValue] = [:]) {
        self.scrambling = scrambling
        self.ir = ir
        self.input = input
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        scrambling = object.bool("scrambling", default: false)
        ir = object.value("ir")
        input = object.value("input", default: [:])
        output = object.value("output", default: [:])
    }
}

public struct AudioFeatures: Decodable, Sendable, Equatable {
    public var arc: [String: JSONValue]?
    public var routing: Bool
    public var dsp: Bool?
    public var input: [String: JSONValue]
    public var output: [String: JSONValue]

    public init(
        arc: [String: JSONValue]? = nil, routing: Bool = false, dsp: Bool? = nil,
        input: [String: JSONValue] = [:], output: [String: JSONValue] = [:]
    ) {
        self.arc = arc
        self.routing = routing
        self.dsp = dsp
        self.input = input
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        arc = object.value("arc")
        routing = object.bool("routing", default: false)
        dsp = object.bool("dsp")
        input = object.value("input", default: [:])
        output = object.value("output", default: [:])
    }
}

public enum BacklightLevel: String, Sendable, CaseIterable {
    case off, low, high
}

public struct SystemFeatures: Decodable, Sendable, Equatable {
    public var result: Bool
    public var updInterval: Int
    public var cec: Bool?
    public var cecSwitching: Bool
    public var cecLogging: Int
    public var cecUsage: Int
    public var pdu: Bool
    public var sky: Bool
    public var hdbaset: Bool
    public var hdbtUpgrade: Bool
    public var mxRemote: Bool
    public var video: VideoFeatures
    public var audio: AudioFeatures
    /// Raw device value, e.g. "High". Use `backlight` for the typed form.
    public var backlightLED: String?
    public var statusLED: String?

    /// Fields are found by name whatever their case or underscores (see `LooseObject`): the vendor library
    /// says `HdbtUpgrade` and `MxRemote`, a real matrix sends `hdbt_upgrade` and `mx_remote`.
    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        result = object.bool("result", default: true)
        updInterval = object.value("updInterval", default: 0)
        cec = object.bool("cec")
        cecSwitching = object.bool("cecSwitching", default: false)
        cecLogging = object.value("cecLogging", default: 0)
        cecUsage = object.value("cecUsage", default: 0)
        pdu = object.bool("pdu", default: false)
        sky = object.bool("sky", default: false)
        hdbaset = object.bool("hdbaset", default: false)
        hdbtUpgrade = object.bool("hdbtUpgrade", default: false)
        mxRemote = object.bool("mxRemote", default: false)
        video = object.value("video", default: VideoFeatures())
        audio = object.value("audio", default: AudioFeatures())
        backlightLED = object.value("backlightLED")
        statusLED = object.value("statusLED")
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

// MARK: - Health

/// One of the matrix's supply rails, with the voltage it measured.
public struct PowerRail: Decodable, Sendable, Equatable {
    public var name: String
    /// Whether the matrix considers the rail within range.
    public var ok: Bool
    /// Volts. 0 for a rail that isn't fitted or isn't used on this model.
    public var volts: Double

    public init(name: String, ok: Bool = true, volts: Double = 0) {
        self.name = name
        self.ok = ok
        self.volts = volts
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        name = object.value("name", default: "")
        ok = object.bool("ok", default: true)
        volts = object.value("value", default: 0)
    }
}

/// A part of the matrix that reports on itself: a power supply, or the set of input or output modules.
public struct HealthComponent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Power supply number 1, 2, ...
        case powerSupply(Int)
        case inputModules
        case outputModules
    }

    public var kind: Kind
    /// 0 is healthy; anything else is the matrix's own fault code.
    public var status: Int
    /// What the matrix says, e.g. "All Present & Healthy".
    public var message: String

    public init(kind: Kind, status: Int, message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }

    public var isHealthy: Bool { status == 0 }
}

/// `/System/Health`: the matrix's own view of how it is doing. Everything is optional, because firmware
/// differs in what it reports (a unit with one power supply has no `PSU2`).
public struct SystemHealth: Decodable, Sendable, Equatable {
    public var result: Bool
    /// 0 is healthy.
    public var status: Int
    public var statusMessage: String
    public var rails: [PowerRail]
    /// Degrees Celsius, from sensor 0 up, in the order the matrix numbers them.
    public var temperatures: [Double]
    public var components: [HealthComponent]
    /// The matrix's firmware update state code. Its meaning isn't documented, so it is shown as is.
    public var updateState: Int?
    /// Seconds since the matrix started.
    public var uptime: Int?

    public init(
        result: Bool = true, status: Int = 0, statusMessage: String = "", rails: [PowerRail] = [],
        temperatures: [Double] = [], components: [HealthComponent] = [], updateState: Int? = nil, uptime: Int? = nil
    ) {
        self.result = result
        self.status = status
        self.statusMessage = statusMessage
        self.rails = rails
        self.temperatures = temperatures
        self.components = components
        self.updateState = updateState
        self.uptime = uptime
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        result = object.bool("result", default: true)
        status = object.value("status", default: 0)
        statusMessage = object.value("statusMessage", default: "")
        rails = object.value("psu", default: [PowerRail]())
        updateState = object.value("sysUpdState")
        uptime = object.value("uptime")

        // Sensors and power supplies are numbered in their key names (`Temperature3`, `PSU1`).
        func numbered(_ prefix: String) -> [(number: Int, key: String)] {
            object.keys.compactMap { key in
                let lower = key.lowercased()
                guard lower.hasPrefix(prefix), let number = Int(lower.dropFirst(prefix.count)) else { return nil }
                return (number, key)
            }.sorted { $0.number < $1.number }
        }
        temperatures = numbered("temperature").compactMap { object.value($0.key, as: Double.self) }

        var parts = numbered("psu").map { supply in
            HealthComponent(
                kind: .powerSupply(supply.number), status: object.value(supply.key, default: 0),
                message: object.value("PSU\(supply.number)Message", default: ""))
        }
        if object.has("inputModules") {
            parts.append(HealthComponent(
                kind: .inputModules, status: object.value("inputModules", default: 0),
                message: object.value("inputModulesMessage", default: "")))
        }
        if object.has("outputModules") {
            parts.append(HealthComponent(
                kind: .outputModules, status: object.value("outputModules", default: 0),
                message: object.value("outputModulesMessage", default: "")))
        }
        components = parts
    }
}

// MARK: - Cloud monitoring

/// `/Monitoring/Settings`: the matrix's link to Pulse-Eight's cloud monitoring service (the same one gotomymatrix.com
/// uses to find it). Read only here.
public struct MonitoringSettings: Decodable, Sendable, Equatable {
    /// Whether the matrix is connected to the cloud service: the `Result` of the call.
    public var cloudConnected: Bool
    /// Seconds since the matrix last reported in. It counts up (an age, not a time of day) and goes back to 0 at
    /// each contact; the matrix reports in about hourly.
    public var lastContact: Int?
    /// The installer account the matrix is registered to.
    public var installerID: String?
    public var autoUpdates: Bool?
    public var updateAvailable: Bool?

    public init(
        cloudConnected: Bool, lastContact: Int? = nil, installerID: String? = nil, autoUpdates: Bool? = nil,
        updateAvailable: Bool? = nil
    ) {
        self.cloudConnected = cloudConnected
        self.lastContact = lastContact
        self.installerID = installerID
        self.autoUpdates = autoUpdates
        self.updateAvailable = updateAvailable
    }

    public init(from decoder: Decoder) throws {
        let object = try LooseObject(decoder)
        cloudConnected = object.bool("result", default: false)
        lastContact = object.value("lastContact")
        // A number on firmware 3.10, but it is an identifier, so text from another version is kept as it came.
        installerID = object.value("installerId", as: Int.self).map(String.init) ?? object.value("installerId", as: String.self)
        autoUpdates = object.bool("autoUpdates")
        updateAvailable = object.bool("updateAvailable")
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
