import PulseEightCore
import PulseEightKit
import SwiftUI

struct PortRow: Identifiable {
    var id: String
    var selection: PortSelection
    var port: String
    var name: String
    var type: String
    var status: PortStatus
    var source: String
    var update: Bool
}

enum BacklightOption: CaseIterable, Hashable {
    case off, dim, bright

    var title: String {
        switch self {
        case .off: "Off"
        case .dim: "Dim"
        case .bright: "Bright"
        }
    }

    var level: BacklightLevel {
        switch self {
        case .off: .off
        case .dim: .low
        case .bright: .high
        }
    }

    init(_ level: BacklightLevel) {
        switch level {
        case .off: self = .off
        case .low: self = .dim
        case .high: self = .bright
        }
    }
}

struct HardwarePage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let state = model.state {
                if let system = state.system {
                    systemSection(system)
                    featuresSection(system.features)
                    if let health = state.health { healthSections(health) }
                    if model.adminConfigured, system.features.backlightLED != nil || system.features.statusLED != nil {
                        frontPanelSection(system.features)
                    }
                } else {
                    Section {
                        if let error = state.systemError {
                            Label("System details couldn't be loaded.", systemImage: "exclamationmark.triangle")
                            Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Text("System details haven't loaded yet.").foregroundStyle(.secondary)
                        }
                    }
                }
                updatesSection(state)
                portsSection(state)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private func systemSection(_ system: SystemInfo) -> some View {
        let d = system.details
        return Section("System") {
            KeyValueRows(pairs: [
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
    }

    /// The matrix's own health report: how it feels overall and each part of it, then temperatures and rails.
    @ViewBuilder
    private func healthSections(_ health: SystemHealth) -> some View {
        let strings = model.core.strings
        Section("Health") {
            LabeledContent("Status") {
                healthValue(health.statusMessage.isEmpty ? String(health.status) : health.statusMessage, healthy: health.status == 0)
            }
            if let uptime = health.uptime {
                LabeledContent(strings.text(.healthUptime)) { Text(Presentation.durationText(seconds: uptime, strings)) }
            }
            ForEach(Array(health.components.enumerated()), id: \.offset) { _, part in
                LabeledContent(Presentation.componentName(part.kind, strings)) {
                    healthValue(part.message.isEmpty ? String(part.status) : part.message, healthy: part.isHealthy)
                }
            }
            if let state = health.updateState {
                LabeledContent(strings.text(.healthUpdateState)) { Text(String(state)).foregroundStyle(.secondary) }
            }
        }
        if !health.temperatures.isEmpty {
            Section("Temperatures") {
                ForEach(Array(health.temperatures.enumerated()), id: \.offset) { index, celsius in
                    LabeledContent("Sensor \(index + 1)") { Text(Presentation.temperatureText(celsius, strings)) }
                }
            }
        }
        if !health.rails.isEmpty {
            Section("Power Rails") {
                ForEach(Array(health.rails.enumerated()), id: \.offset) { _, rail in
                    LabeledContent(rail.name) {
                        Text(Presentation.voltageText(rail, strings))
                            .foregroundStyle(rail.ok ? Color.primary : Color.red)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// A status in words, with a tick or a warning beside it.
    private func healthValue(_ text: String, healthy: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(healthy ? Color.green : Color.orange)
            Text(text)
        }
    }

    private func featuresSection(_ f: SystemFeatures) -> some View {
        Section("Features") {
            KeyValueRows(pairs: [
                ("HDBaseT", yesNo(f.hdbaset)),
                ("HDBaseT upgrade capable", yesNo(f.hdbtUpgrade)),
                ("CEC", f.cec.map(yesNo)),
                ("CEC switching", yesNo(f.cecSwitching)),
                ("PoE / PDU", yesNo(f.pdu)),
                ("Sky control", yesNo(f.sky)),
                ("MX Remote", yesNo(f.mxRemote)),
                ("Audio routing", yesNo(f.audio.routing)),
                ("Video scrambling", yesNo(f.video.scrambling)),
                ("Update interval", formatMs(f.updInterval)),
            ])
        }
    }

    private func frontPanelSection(_ f: SystemFeatures) -> some View {
        Section("Front Panel") {
            if let level = f.backlight {
                Picker("Backlight", selection: backlightBinding(current: level)) {
                    ForEach(BacklightOption.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.backlightPending != nil)
            }
            if let on = f.statusLEDOn {
                Toggle("Status LED", isOn: statusLEDBinding(current: on))
                    .disabled(model.statusLEDPending != nil)
            }
            if let error = model.frontPanelError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private func updatesSection(_ state: MatrixState) -> some View {
        Section("Firmware Updates") {
            if state.updates.isEmpty {
                Text("No updates detected.").foregroundStyle(.secondary)
            } else {
                ForEach(state.updates) { update in
                    Button {
                        model.openPort(PortSelection(mode: .output, bay: update.bay))
                    } label: {
                        LabeledContent(update.name) {
                            HStack(spacing: 6) {
                                Text("Update available").foregroundStyle(.orange)
                                if let version = update.firmwareVersion {
                                    Text("current \(version)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func portsSection(_ state: MatrixState) -> some View {
        let rows = portRows(state)
        return Section {
            if rows.isEmpty {
                Text("No ports discovered yet.").foregroundStyle(.secondary)
            } else {
                portRowView("Port", "Name", "Type", nil, "Source", header: true)
                ForEach(rows) { row in
                    Button {
                        model.openPort(row.selection)
                    } label: {
                        portRowView(row.port, row.name, row.type, row, row.source, header: false)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Ports")
        } footer: {
            if !rows.isEmpty { Text("Click a port to see details.") }
        }
    }

    private func portRowView(
        _ port: String, _ name: String, _ type: String, _ row: PortRow?, _ source: String, header: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(port).frame(width: 80, alignment: .leading)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(type).frame(width: 90, alignment: .leading)
            Group {
                if let row {
                    HStack(spacing: 6) {
                        StatusDot(status: row.status)
                        Text(row.update ? "\(row.status.label) · update" : row.status.label)
                    }
                } else {
                    Text("Status")
                }
            }
            .frame(width: 170, alignment: .leading)
            Text(source).frame(width: 110, alignment: .leading)
        }
        .lineLimit(1)
        .foregroundStyle(header ? .secondary : .primary)
        .font(header ? .callout : .body)
    }

    // MARK: Helpers

    private func portRows(_ state: MatrixState) -> [PortRow] {
        (state.inputs + state.outputs).map { port in
            let outputDetails = port.mode == .output ? state.outputDetails[port.bay] : nil
            let source = port.mode == .output
                ? port.receiveFrom.map { bay in state.inputs.first { $0.bay == bay }?.name ?? "Input \(bay + 1)" }
                : nil
            return PortRow(
                id: port.id,
                selection: PortSelection(mode: port.mode, bay: port.bay),
                port: "\(port.mode.rawValue) \(port.bay + 1)",
                name: port.name,
                type: port.type,
                status: port.status,
                source: source ?? "–",
                update: outputDetails?.firmwareVersionAvailable == true
            )
        }
    }

    private func backlightBinding(current: BacklightLevel) -> Binding<BacklightOption> {
        Binding(
            get: { BacklightOption(model.backlightPending ?? current) },
            set: { if $0.level != (model.backlightPending ?? current) { model.setBacklight($0.level) } }
        )
    }

    private func statusLEDBinding(current: Bool) -> Binding<Bool> {
        Binding(
            get: { model.statusLEDPending ?? current },
            set: { model.setStatusLED(on: $0) }
        )
    }

    private func formatMs(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\((minutes * 10).rounded() / 10)m" }
        return "\((minutes / 60 * 10).rounded() / 10)h"
    }
}
