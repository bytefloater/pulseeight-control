import Foundation

/// In-memory stand-in for a NeoMatrix. Serves every endpoint PulseEightKit uses:
///
///     GET  /System/Details, /system/features, /System/Health
///     GET  /Port/List
///     GET  /Port/Details/{Input|Output}/{bay}
///     GET  /Port/Set/{input}/{output}
///     GET  /Port/EDID/Set/{profile}/{bay}                (admin)
///     POST /Account/Login                                {"Password": ...}
///     POST /Port/SetName/{Input|Output}/{bay}/           {"Name": ...} (admin)
///     POST /System/BacklightLED/{off|low|high}           (admin)
///     POST /System/StatusLED/{On|Off}                    (admin)
///
/// Payload shapes are synthetic, but the system ones spell their keys as a real NeoMatrix (firmware
/// 3.10) does (`revision`, `hdbt_upgrade`, `IR`...), because the vendor library's spellings once hid a bug. Thread-safe: requests are handled one at a time under a lock.
public final class FakeMatrix: @unchecked Sendable {
    public struct Options: Sendable {
        /// Inputs and outputs per side (8 or 16 on real hardware).
        public var bays: Int
        /// Admin password; nil lets admin calls through without a login.
        public var password: String?
        /// Seconds added to every reply, to see pending states in a UI.
        public var latency: TimeInterval

        public init(bays: Int = 8, password: String? = nil, latency: TimeInterval = 0) {
            self.bays = max(1, bays)
            self.password = password
            self.latency = latency
        }
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
    }

    /// Longest port name the device's own rename field accepts.
    public static let nameMax = 13

    private struct Input { var name: String; var status: Int; var edid: Int }
    private struct Output { var name: String; var status: Int; var source: Int; var firmware: String; var firmwareAvailable: Bool }

    public let options: Options
    private let lock = NSLock()
    // The real device issues no session cookie, so "logged in" is just the last login result.
    private var loggedIn = false
    private var backlight = "High"
    private var statusLED = "On"
    /// For the uptime the health report gives.
    private let started = Date()
    private var inputs: [Input]
    private var outputs: [Output]

    public init(_ options: Options = Options()) {
        self.options = options
        let bays = options.bays
        inputs = (0..<bays).map { Input(name: "Input \($0 + 1)", status: $0 % 3 != 2 ? 0 : 3, edid: 0) }
        inputs[0].name = "Sky"
        if bays > 1 { inputs[1].name = "Apple TV" }
        outputs = (0..<bays).map {
            Output(name: "Output \($0 + 1)", status: 0, source: $0 % bays, firmware: "1.0.0", firmwareAvailable: $0 == 2)
        }
        outputs[0].name = "Lounge TV"
        if bays > 1 { outputs[1].name = "Bedroom TV" }
    }

    /// Handles one request. Returns nil for an unknown path (the server answers 404).
    /// The path is the URL path only, without the query.
    public func handle(method: String, path: String, body: Data?) -> Response? {
        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let result: [String: Any]? = lock.locked { route(method: method, path: path, body: json) }
        guard let result, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return nil }
        return Response(status: 200, body: data)
    }

    // MARK: Routing

    private func route(method: String, path: String, body: [String: Any]) -> [String: Any]? {
        let parts = path.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let bays = options.bays

        switch (method, parts.count) {
        case ("GET", 2):
            switch (parts[0], parts[1]) {
            case ("system", "details"): return details()
            case ("system", "features"): return features()
            case ("system", "health"): return health()
            case ("port", "list"): return portList()
            default: return nil
            }
        case ("GET", 4):
            if parts[0] == "port", parts[1] == "details", ["input", "output"].contains(parts[2]), let bay = number(parts[3]) {
                guard bay < bays else { return Self.failure("No such port") }
                return portDetails(mode: parts[2].capitalized, bay: bay)
            }
            if parts[0] == "port", parts[1] == "set", let input = number(parts[2]), let output = number(parts[3]) {
                return setRoute(input: input, output: output)
            }
            return nil
        case ("GET", 5):
            guard parts[0] == "port", parts[1] == "edid", parts[2] == "set",
                  let profile = number(parts[3]), let bay = number(parts[4]) else { return nil }
            if let denied = requireAdmin() { return denied }
            guard bay < bays else { return Self.failure("No such port") }
            inputs[bay].edid = profile
            return ["Result": true]
        case ("POST", 2):
            guard parts[0] == "account", parts[1] == "login" else { return nil }
            return login(body)
        case ("POST", 3):
            if parts[0] == "system", parts[1] == "backlightled", ["off", "low", "high"].contains(parts[2]) {
                if let denied = requireAdmin() { return denied }
                backlight = parts[2].capitalized
                return ["Result": true]
            }
            if parts[0] == "system", parts[1] == "statusled", ["on", "off"].contains(parts[2]) {
                if let denied = requireAdmin() { return denied }
                statusLED = parts[2].capitalized
                return ["Result": true]
            }
            return nil
        case ("POST", 4):
            guard parts[0] == "port", parts[1] == "setname", ["input", "output"].contains(parts[2]), let bay = number(parts[3])
            else { return nil }
            if let denied = requireAdmin() { return denied }
            let name = body["Name"] as? String ?? ""
            guard bay < bays, name.count <= Self.nameMax else { return Self.failure("Invalid name or port") }
            if parts[2] == "input" { inputs[bay].name = name } else { outputs[bay].name = name }
            return ["Result": true]
        default:
            return nil
        }
    }

    /// A non-negative whole number (the device's paths never carry signs).
    private func number(_ text: String) -> Int? {
        text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) ? Int(text) : nil
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["Result": false, "Message": message]
    }

    // MARK: Endpoints

    private func details() -> [String: Any] {
        [
            "Result": true, "Model": "NeoMatrix (fake)", "Version": "1.2.3", "Serial": "FAKE0001",
            "MAC": "00:11:22:33:44:55", "VID": "1234", "BoardRev": 2,
            "revision": ["main": 1, "top": 2, "ir": 3], "Locale": "en-GB",
            "StatusMessage": "OK", "Status": 0,
        ]
    }

    private func features() -> [String: Any] {
        let bays = options.bays
        return [
            "Result": true, "UpdInterval": 5000, "CEC": 1, "CEC_Switching": false, "CEC_Logging": 0,
            "CEC_Usage": 1, "PDU": false, "Sky": true, "HDBaseT": true, "hdbt_upgrade": true,
            "mx_remote": false,
            "Video": ["Scrambling": true, "IR": ["Learn": true, "Blast": false], "Input": ["Bays": bays], "Output": ["Bays": bays]] as [String: Any],
            "Audio": ["ARC": ["support": false], "Routing": true, "DSP": false, "Input": ["Bays": bays], "Output": ["Bays": bays]] as [String: Any],
            "BacklightLED": backlight, "StatusLED": statusLED,
        ]
    }

    private func health() -> [String: Any] {
        let rails: [[String: Any]] = [
            ["name": "3.3V", "ok": true, "value": 3.3969], ["name": "5V", "ok": true, "value": 5.0892],
            ["name": "12V", "ok": true, "value": 12.2565], ["name": "PoE", "ok": true, "value": 57.0767],
        ]
        return [
            "Result": true, "psu": rails, "Locale": "en-GB", "StatusMessage": "Healthy", "Status": 0,
            "Temperature0": 31, "Temperature1": 31, "Temperature2": 31, "Temperature3": 36, "Temperature4": 33,
            "PSU1Message": "Present & Healthy", "PSU1": 0,
            "InputModulesMessage": "All Present & Healthy", "InputModules": 0,
            "OutputModulesMessage": "All Present & Healthy", "OutputModules": 0,
            "SysUpdState": 6, "Uptime": Int(Date().timeIntervalSince(started)),
        ]
    }

    private func portList() -> [String: Any] {
        var ports: [[String: Any]] = inputs.enumerated().map { bay, port in
            ["Bay": bay, "Mode": "Input", "Type": "HDMI IN", "Status": port.status, "Name": port.name]
        }
        ports += outputs.enumerated().map { bay, port in
            ["Bay": bay, "Mode": "Output", "Type": "HDBT OUT", "Status": port.status, "Name": port.name,
             "ReceiveFrom": port.source]
        }
        return ["Result": true, "Ports": ports]
    }

    private func portDetails(mode: String, bay: Int) -> [String: Any] {
        if mode == "Input" {
            let port = inputs[bay]
            let ok = port.status == 0
            return [
                "Result": true, "Bay": bay, "Mode": "Input", "Type": "HDMI IN", "Status": port.status,
                "Name": port.name, "StatusMessage": ok ? "OK" : "No HDMI Signal",
                "HPD": 1, "HasSignal": ok, "VideoSignal": ok ? "3840x2160@60" : "", "Signal": "HDMI",
                "HDCP": 1, "EdidProfile": port.edid,
            ]
        }
        let port = outputs[bay]
        return [
            "Result": true, "Bay": bay, "Mode": "Output", "Type": "HDBT OUT", "Status": port.status,
            "Name": port.name, "StatusMessage": "OK", "ReceiveFrom": port.source, "POE": true,
            "FirmwareVersion": port.firmware, "FirmwareVersionAvailable": port.firmwareAvailable,
            "OverrideEDID": ["Address": "0x50", "Setting": 3] as [String: Any],
        ]
    }

    private func setRoute(input: Int, output: Int) -> [String: Any] {
        guard input < options.bays, output < options.bays else { return Self.failure("Invalid port") }
        outputs[output].source = input
        return ["Result": true, "Message": "Changed"]
    }

    private func login(_ body: [String: Any]) -> [String: Any] {
        if options.password == nil || body["Password"] as? String == options.password {
            loggedIn = true
            return ["Result": true]
        }
        loggedIn = false
        return Self.failure("Incorrect password")
    }

    private func requireAdmin() -> [String: Any]? {
        if options.password != nil, !loggedIn { return Self.failure("Login required") }
        return nil
    }
}

extension NSLock {
    fileprivate func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
