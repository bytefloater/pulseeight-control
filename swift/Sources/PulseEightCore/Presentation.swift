import Foundation
import PulseEightKit

/// A label/value line, as shown in the Hardware cards and the port detail sheet.
public struct LabeledValue: Codable, Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Text shown by both apps, so the two UIs say the same thing. Lines the matrix didn't report
/// are left out, like the old web UI's key/value cards.
public enum Presentation {
    public static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    public static func intervalText(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\((minutes * 10).rounded() / 10)m" }
        return "\((minutes / 60 * 10).rounded() / 10)h"
    }

    private static func rows(_ pairs: [(String, String?)]) -> [LabeledValue] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return LabeledValue(label, value)
        }
    }

    public static func systemRows(_ system: SystemInfo) -> [LabeledValue] {
        let d = system.details
        return rows([
            ("Model", d.model),
            ("Firmware version", d.version),
            ("Serial", d.serial),
            ("MAC address", d.mac),
            ("VID", d.vid),
            ("Board revision", String(d.boardRev)),
            ("Locale", d.locale),
            ("Status", d.statusMessage),
        ])
    }

    public static func featureRows(_ f: SystemFeatures) -> [LabeledValue] {
        rows([
            ("HDBaseT", yesNo(f.hdbaset)),
            ("HDBaseT upgrade capable", yesNo(f.hdbtUpgrade)),
            ("CEC", f.cec.map(yesNo)),
            ("CEC switching", yesNo(f.cecSwitching)),
            ("PoE / PDU", yesNo(f.pdu)),
            ("Sky control", yesNo(f.sky)),
            ("MX Remote", yesNo(f.mxRemote)),
            ("Audio routing", yesNo(f.audio.routing)),
            ("Video scrambling", yesNo(f.video.scrambling)),
            ("Update interval", intervalText(milliseconds: f.updInterval)),
        ])
    }

    /// Detail lines for one port. Empty until the details have loaded.
    public static func portRows(_ port: MatrixPort, in state: MatrixState) -> [LabeledValue] {
        func sourceName(_ bay: Int) -> String {
            state.inputs.first { $0.bay == bay }?.name ?? "Input \(bay + 1)"
        }
        switch port.mode {
        case .input:
            guard let details = state.inputDetails[port.bay] else { return [] }
            let base = details.base
            return rows([
                ("Status", base.statusDescription),
                ("Type", base.type),
                ("Has signal", base.hasSignal.map(yesNo)),
                ("Signal", base.videoSignal),
                ("Source type", base.signal),
                ("HDCP", details.hdcp.map(String.init)),
            ])
        case .output:
            guard let details = state.outputDetails[port.bay] else { return [] }
            let base = details.base
            var firmware: String?
            if let version = details.firmwareVersion, !version.isEmpty {
                firmware = "\(version)  (\(details.firmwareVersionAvailable == true ? "update available" : "up to date"))"
            }
            return rows([
                ("Status", base.statusDescription),
                ("Type", base.type),
                ("Has signal", base.hasSignal.map(yesNo)),
                ("Signal", base.videoSignal ?? base.signal),
                ("Routed from input", port.receiveFrom.map(sourceName)),
                ("Link status", details.linkStatus),
                ("Cable length (est.)", details.estimatedCableLength.flatMap { $0 > 0 ? "\($0) m" : nil }),
                ("Sink vendor", details.vendor),
                ("Sink model", details.monitorName),
                ("PoE", details.poe.map { $0 ? "On" : "Off" }),
                ("Firmware version", firmware),
                ("TMDS", details.linkQuality.map { String($0.tmds) }),
                ("Total BER", details.linkQuality.map { String($0.totalBER) }),
            ])
        }
    }
}
