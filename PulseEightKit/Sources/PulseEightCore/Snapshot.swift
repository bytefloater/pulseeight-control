import Foundation
import PulseEightKit

/// Everything a UI needs to draw itself, as plain data with stable names. This is the contract
/// the Windows app reads (as JSON); `schema` is bumped for breaking changes.
public struct CoreSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public struct SettingsSnapshot: Codable, Equatable, Sendable {
        public var appearance: String
        public var highlightGrid: Bool
        public var showStatusBar: Bool
        /// Whether the app looks for updates by itself (the Windows updater reads this).
        public var checkForUpdates: Bool
        /// The saved choice: a language code, or "system".
        public var language: String
        public var host: String?
        public var port: Int
        public var timeout: Int
        public var pollInterval: Int
        public var detailPollInterval: Int
    }

    public struct PortSnapshot: Codable, Equatable, Sendable {
        /// "Input" or "Output".
        public var mode: String
        /// Zero-based, as the matrix numbers it.
        public var bay: Int
        /// One-based, as people number it.
        public var number: Int
        public var name: String
        public var type: String
        /// 0 ok, 1 module fault, 2 warning, 3 no signal, 4 not present.
        public var status: Int
        public var statusLabel: String
        /// Outputs only: bay of the routed input.
        public var receiveFrom: Int?
        /// Outputs only: name of the routed input.
        public var sourceName: String?
        public var updateAvailable: Bool
        /// Inputs only.
        public var edidProfile: Int?
        public var details: [LabeledValue]
    }

    public struct UpdateSnapshot: Codable, Equatable, Sendable {
        public var bay: Int
        public var name: String
        public var firmwareVersion: String?
    }

    public struct LanguageSnapshot: Codable, Equatable, Sendable {
        public var code: String
        /// The language's own name for itself.
        public var name: String
    }

    public struct EdidSnapshot: Codable, Equatable, Sendable {
        public var id: Int
        public var name: String
    }

    public struct FrontPanelSnapshot: Codable, Equatable, Sendable {
        /// "off", "low" or "high"; nil when the matrix has no backlight control.
        public var backlight: String?
        public var statusLed: Bool?
    }

    public var schema = CoreSnapshot.currentSchema
    /// notConfigured, connecting, connected or disconnected.
    public var phase: String
    /// Why the connection failed, when it did.
    public var phaseDetail: String?
    /// "Connected to 192.168.1.150".
    public var summary: String
    public var hostLabel: String
    public var adminConfigured: Bool
    /// Code of the language in force (the saved choice, or the OS's when that is "system").
    public var language: String
    /// Every available language, for a picker.
    public var languages: [LanguageSnapshot]
    public var settings: SettingsSnapshot
    public var inputs: [PortSnapshot]
    public var outputs: [PortSnapshot]
    public var systemRows: [LabeledValue]
    public var featureRows: [LabeledValue]
    public var model: String?
    public var firmware: String?
    public var frontPanel: FrontPanelSnapshot?
    public var updates: [UpdateSnapshot]
    public var edidProfiles: [EdidSnapshot]
}

extension CoreSnapshot {
    public init(core: AppCore) {
        self.init(
            update: core.update, summary: core.connectionSummary, hostLabel: core.hostLabel,
            edidProfiles: core.edidProfiles(), strings: core.strings
        )
    }

    public init(update: CoreUpdate, summary: String, hostLabel: String, edidProfiles: [EdidProfile], strings: Strings) {
        var detail: String?
        if case .disconnected(let reason) = update.phase { detail = reason }
        let state = update.state
        let matrix = update.settings.matrix

        func snapshot(_ port: MatrixPort, in state: MatrixState) -> PortSnapshot {
            let outputDetails = port.mode == .output ? state.outputDetails[port.bay] : nil
            let edid = port.mode == .input ? state.inputDetails[port.bay]?.edidProfile : nil
            return PortSnapshot(
                mode: port.mode.rawValue,
                bay: port.bay,
                number: port.bay + 1,
                name: port.name,
                type: port.type,
                status: port.status.rawValue,
                statusLabel: Presentation.statusLabel(port.status, strings),
                receiveFrom: port.receiveFrom,
                sourceName: port.mode == .output
                    ? port.receiveFrom.map { bay in state.inputs.first { $0.bay == bay }?.name ?? strings.text(.portDefaultInputName, bay + 1) }
                    : nil,
                updateAvailable: outputDetails?.firmwareVersionAvailable == true,
                edidProfile: edid,
                details: Presentation.portRows(port, in: state, strings)
            )
        }

        var frontPanel: FrontPanelSnapshot?
        if let features = state?.system?.features, features.backlightLED != nil || features.statusLED != nil {
            frontPanel = FrontPanelSnapshot(backlight: features.backlight?.rawValue, statusLed: features.statusLEDOn)
        }

        self.init(
            phase: update.phase.name,
            phaseDetail: detail,
            summary: summary,
            hostLabel: hostLabel,
            adminConfigured: update.adminConfigured,
            language: strings.language.code,
            languages: Languages.all.map { LanguageSnapshot(code: $0.code, name: $0.nativeName) },
            settings: SettingsSnapshot(
                appearance: update.settings.appearance.rawValue,
                highlightGrid: update.settings.highlightGrid,
                showStatusBar: update.settings.showStatusBar,
                checkForUpdates: update.settings.checkForUpdates,
                language: update.settings.language,
                host: matrix.host,
                port: matrix.port,
                timeout: matrix.timeout,
                pollInterval: matrix.pollInterval,
                detailPollInterval: matrix.detailPollInterval
            ),
            inputs: state.map { s in s.inputs.map { snapshot($0, in: s) } } ?? [],
            outputs: state.map { s in s.outputs.map { snapshot($0, in: s) } } ?? [],
            systemRows: state?.system.map { Presentation.systemRows($0, strings) } ?? [],
            featureRows: state?.system.map { Presentation.featureRows($0.features, strings) } ?? [],
            model: state?.system?.details.model,
            firmware: state?.system?.details.version,
            frontPanel: frontPanel,
            updates: state?.updates.map { UpdateSnapshot(bay: $0.bay, name: $0.name, firmwareVersion: $0.firmwareVersion) } ?? [],
            edidProfiles: edidProfiles.map { EdidSnapshot(id: $0.id, name: $0.name) }
        )
    }

    /// Compact JSON with stable key order, for the C interface.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
