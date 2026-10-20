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
        /// Whether updates may be release candidates and betas; nil follows the installed build (see `AppSettings`).
        public var updatePrereleases: Bool?
        /// The saved choice: a language code, or "system".
        public var language: String
        public var host: String?
        public var port: Int
        public var timeout: Int
        public var pollInterval: Int
        public var detailPollInterval: Int
    }

    /// One of the configured matrices. The admin password itself is never part of a snapshot.
    public struct MatrixSnapshot: Codable, Equatable, Sendable {
        /// Pass to `selectMatrix`, `saveMatrix` and `removeMatrix`.
        public var id: String
        /// What the person called it, possibly empty.
        public var name: String
        /// The name, or the address when there is no name.
        public var displayName: String
        public var host: String?
        public var port: Int
        public var timeout: Int
        public var pollInterval: Int
        public var detailPollInterval: Int
        public var adminPasswordSaved: Bool
        public var selected: Bool
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
    /// Every configured matrix, in the order they were added.
    public var matrices: [MatrixSnapshot]
    public var inputs: [PortSnapshot]
    public var outputs: [PortSnapshot]
    /// Why the system details couldn't be loaded (they are missing while this is set).
    public var systemError: String?
    public var systemRows: [LabeledValue]
    /// The matrix's own health report (status, uptime, supplies, temperatures, rails); empty until it loads
    /// and for firmware without one.
    public var healthRows: [LabeledValue]
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
            edidProfiles: core.edidProfiles(), strings: core.strings,
            adminPasswordSaved: Set(core.matrices.map(\.id).filter { core.hasAdminPassword(for: $0) })
        )
    }

    public init(
        update: CoreUpdate, summary: String, hostLabel: String, edidProfiles: [EdidProfile], strings: Strings,
        adminPasswordSaved: Set<UUID> = []
    ) {
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
                updatePrereleases: update.settings.updatePrereleases,
                language: update.settings.language,
                host: matrix.host,
                port: matrix.port,
                timeout: matrix.timeout,
                pollInterval: matrix.pollInterval,
                detailPollInterval: matrix.detailPollInterval
            ),
            matrices: update.settings.matrices.map { profile in
                MatrixSnapshot(
                    id: profile.id.uuidString.lowercased(), name: profile.name, displayName: profile.displayName,
                    host: profile.config.host, port: profile.config.port, timeout: profile.config.timeout,
                    pollInterval: profile.config.pollInterval, detailPollInterval: profile.config.detailPollInterval,
                    adminPasswordSaved: adminPasswordSaved.contains(profile.id),
                    selected: profile.id == update.settings.selectedMatrix?.id)
            },
            inputs: state.map { s in s.inputs.map { snapshot($0, in: s) } } ?? [],
            outputs: state.map { s in s.outputs.map { snapshot($0, in: s) } } ?? [],
            systemError: state?.systemError,
            systemRows: state?.system.map { Presentation.systemRows($0, strings) } ?? [],
            healthRows: Presentation.healthRows(health: state?.health, monitoring: state?.monitoring, strings),
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
