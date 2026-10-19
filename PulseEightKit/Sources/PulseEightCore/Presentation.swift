import Foundation
import PulseEightKit

/// A label/value line, as shown in the Hardware cards and the port detail sheet.
public struct LabeledValue: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    /// Health rows only: whether what the line describes is in good order (nil when that isn't a judgement the
    /// matrix makes, e.g. uptime). Not in the JSON when nil.
    public var ok: Bool?
    /// Health rows only: `health` for the matrix's own verdict and its parts, `diagnostics` for the raw readings
    /// (temperatures, supply rails). Not in the JSON when nil.
    public var group: String?

    public init(_ label: String, _ value: String, ok: Bool? = nil, group: String? = nil) {
        self.label = label
        self.value = value
        self.ok = ok
        self.group = group
    }
}

/// Text shown by both apps, so the two UIs say the same thing, in the language `Strings` carries.
/// Lines the matrix didn't report are left out, like the old web UI's key/value cards.
public enum Presentation {
    public static func yesNo(_ value: Bool, _ strings: Strings) -> String {
        strings.text(value ? .commonYes : .commonNo)
    }

    public static func intervalText(milliseconds: Int, _ strings: Strings) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return strings.text(.intervalSeconds, Int(seconds)) }
        let minutes = seconds / 60
        if minutes < 60 { return strings.text(.intervalMinutes, (minutes * 10).rounded() / 10) }
        return strings.text(.intervalHours, (minutes / 60 * 10).rounded() / 10)
    }

    /// "2d 3h 14m", "5m", "40s": the two or three largest units that aren't zero.
    public static func durationText(seconds total: Int, _ strings: Strings) -> String {
        let seconds = max(total, 0)
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        var parts: [String] = []
        if days > 0 { parts.append(strings.text(.durationDays, days)) }
        if days > 0 || hours > 0 { parts.append(strings.text(.durationHours, hours)) }
        if days == 0 { parts.append(strings.text(.durationMinutes, minutes)) }
        if seconds < 60 { return strings.text(.intervalSeconds, seconds) }
        return parts.joined(separator: " ")
    }

    /// Degrees with at most one decimal: "31 °C", "31.5 °C".
    public static func temperatureText(_ celsius: Double, _ strings: Strings) -> String {
        strings.text(.healthDegrees, numberText(celsius, decimals: 1))
    }

    public static func voltageText(_ rail: PowerRail, _ strings: Strings) -> String {
        let text = strings.text(.healthVolts, String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rail.volts))
        return rail.ok ? text : strings.text(.healthRailOutOfRange, text)
    }

    /// What the matrix calls a part of itself, by kind.
    public static func componentName(_ kind: HealthComponent.Kind, _ strings: Strings) -> String {
        switch kind {
        case .powerSupply(let number): strings.text(.healthPowerSupply, number)
        case .inputModules: strings.text(.healthInputModules)
        case .outputModules: strings.text(.healthOutputModules)
        }
    }

    /// Whole numbers without a decimal point, others to `decimals` places with trailing zeros dropped.
    private static func numberText(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// The health report as label/value lines, for UIs that show plain rows.
    public static func healthRows(_ health: SystemHealth, _ strings: Strings) -> [LabeledValue] {
        healthRows(health: health, monitoring: nil, strings)
    }

    /// The health report with the cloud link (`/Monitoring/Settings`) after it: whether the matrix is connected to the
    /// cloud service, how long ago it last reported in, and the installer it is registered to. Either part may be missing.
    public static func healthRows(health: SystemHealth?, monitoring: MonitoringSettings?, _ strings: Strings) -> [LabeledValue] {
        func row(_ label: String, _ value: String?, ok: Bool? = nil, group: String) -> LabeledValue? {
            guard let value, !value.isEmpty else { return nil }
            return LabeledValue(label, value, ok: ok, group: group)
        }
        var result: [LabeledValue?] = []

        if let health {
            result.append(row(strings.text(.rowStatus), health.statusMessage, ok: health.status == 0, group: "health"))
            result.append(row(strings.text(.healthUptime), health.uptime.map { durationText(seconds: $0, strings) }, group: "health"))
            for part in health.components {
                result.append(row(
                    componentName(part.kind, strings), part.message.isEmpty ? String(part.status) : part.message,
                    ok: part.isHealthy, group: "health"))
            }
            for (index, celsius) in health.temperatures.enumerated() {
                result.append(row(strings.text(.healthTemperature, index + 1), temperatureText(celsius, strings), group: "diagnostics"))
            }
            for rail in health.rails {
                result.append(row(strings.text(.healthRail, rail.name), voltageText(rail, strings), ok: rail.ok, group: "diagnostics"))
            }
            result.append(row(strings.text(.healthUpdateState), health.updateState.map(String.init), group: "health"))
        }

        if let monitoring {
            result.append(row(
                strings.text(.healthCloudConnection),
                strings.text(monitoring.cloudConnected ? .healthCloudConnected : .healthCloudDisconnected),
                ok: monitoring.cloudConnected, group: "health"))
            result.append(row(
                strings.text(.healthLastContact),
                monitoring.lastContact.map { strings.text(.healthAgo, durationText(seconds: $0, strings)) }, group: "health"))
            result.append(row(strings.text(.healthInstallerId), monitoring.installerID, group: "health"))
        }
        return result.compactMap { $0 }
    }

    /// "Input" / "Output".
    public static func modeName(_ mode: PortMode, _ strings: Strings) -> String {
        strings.text(mode == .input ? .portInput : .portOutput)
    }

    /// Short status ("OK", "No signal").
    public static func statusLabel(_ status: PortStatus, _ strings: Strings) -> String {
        switch status {
        case .ok: strings.text(.portStatusOK)
        case .moduleFault: strings.text(.portStatusModuleFault)
        case .warning: strings.text(.portStatusWarning)
        case .noSignal: strings.text(.portStatusNoSignal)
        case .moduleNotPresent: strings.text(.portStatusNotPresent)
        }
    }

    /// Longer status for the detail rows ("No HDMI Signal", "Output is Faulty").
    static func statusDescription(_ base: BasePortDetails, _ strings: Strings) -> String {
        switch base.status {
        case .noSignal: strings.text(base.type == "AUDIO IN" ? .portStatusAudioOnly : .portStatusNoHDMISignal)
        case .moduleNotPresent: strings.text(.portStatusModeNotPresent, modeName(base.mode, strings))
        case .moduleFault: strings.text(.portStatusModeFaulty, modeName(base.mode, strings))
        case .ok: strings.text(.portStatusOK)
        case .warning: strings.text(.portStatusWarning)
        }
    }

    private static func rows(_ pairs: [(String, String?)]) -> [LabeledValue] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return LabeledValue(label, value)
        }
    }

    public static func systemRows(_ system: SystemInfo, _ strings: Strings) -> [LabeledValue] {
        let d = system.details
        return rows([
            (strings.text(.rowModel), d.model),
            (strings.text(.rowFirmwareVersion), d.version),
            (strings.text(.rowSerial), d.serial),
            (strings.text(.rowMAC), d.mac),
            (strings.text(.rowVID), d.vid),
            (strings.text(.rowBoardRevision), String(d.boardRev)),
            (strings.text(.rowLocale), d.locale),
            (strings.text(.rowStatus), d.statusMessage),
        ])
    }

    public static func featureRows(_ f: SystemFeatures, _ strings: Strings) -> [LabeledValue] {
        func yes(_ value: Bool) -> String { yesNo(value, strings) }
        return rows([
            (strings.text(.featureHDBaseT), yes(f.hdbaset)),
            (strings.text(.featureHDBaseTUpgrade), yes(f.hdbtUpgrade)),
            (strings.text(.featureCEC), f.cec.map(yes)),
            (strings.text(.featureCECSwitching), yes(f.cecSwitching)),
            (strings.text(.featurePoePdu), yes(f.pdu)),
            (strings.text(.featureSky), yes(f.sky)),
            (strings.text(.featureMXRemote), yes(f.mxRemote)),
            (strings.text(.featureAudioRouting), yes(f.audio.routing)),
            (strings.text(.featureVideoScrambling), yes(f.video.scrambling)),
            (strings.text(.featureUpdateInterval), intervalText(milliseconds: f.updInterval, strings)),
        ])
    }

    /// Detail lines for one port. Empty until the details have loaded.
    public static func portRows(_ port: MatrixPort, in state: MatrixState, _ strings: Strings) -> [LabeledValue] {
        func sourceName(_ bay: Int) -> String {
            state.inputs.first { $0.bay == bay }?.name ?? strings.text(.portDefaultInputName, bay + 1)
        }
        func yes(_ value: Bool) -> String { yesNo(value, strings) }
        switch port.mode {
        case .input:
            guard let details = state.inputDetails[port.bay] else { return [] }
            let base = details.base
            return rows([
                (strings.text(.detailStatus), statusDescription(base, strings)),
                (strings.text(.detailType), base.type),
                (strings.text(.detailHasSignal), base.hasSignal.map(yes)),
                (strings.text(.detailSignal), base.videoSignal),
                (strings.text(.detailSourceType), base.signal),
                (strings.text(.detailHDCP), details.hdcp.map(String.init)),
            ])
        case .output:
            guard let details = state.outputDetails[port.bay] else { return [] }
            let base = details.base
            var firmware: String?
            if let version = details.firmwareVersion, !version.isEmpty {
                firmware = strings.text(details.firmwareVersionAvailable == true ? .detailFirmwareUpdateAvailable : .detailFirmwareUpToDate, version)
            }
            return rows([
                (strings.text(.detailStatus), statusDescription(base, strings)),
                (strings.text(.detailType), base.type),
                (strings.text(.detailHasSignal), base.hasSignal.map(yes)),
                (strings.text(.detailSignal), base.videoSignal ?? base.signal),
                (strings.text(.detailRoutedFrom), port.receiveFrom.map(sourceName)),
                (strings.text(.detailLinkStatus), details.linkStatus),
                (strings.text(.detailCableLength), details.estimatedCableLength.flatMap { $0 > 0 ? strings.text(.detailCableLengthValue, $0) : nil }),
                (strings.text(.detailSinkVendor), details.vendor),
                (strings.text(.detailSinkModel), details.monitorName),
                (strings.text(.detailPoE), details.poe.map { strings.text($0 ? .commonOn : .commonOff) }),
                (strings.text(.detailFirmwareVersion), firmware),
                (strings.text(.detailTMDS), details.linkQuality.map { String($0.tmds) }),
                (strings.text(.detailTotalBER), details.linkQuality.map { String($0.totalBER) }),
            ])
        }
    }
}
