import PulseEightKit
import SwiftCrossUI

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

enum BacklightOption: CaseIterable, CustomStringConvertible {
    case off, dim, bright

    var description: String {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hardware").font(.title2)
                if let state = model.state {
                    if let system = state.system {
                        systemCard(system)
                        featuresCard(system.features)
                        if model.adminConfigured, system.features.backlightLED != nil || system.features.statusLED != nil {
                            frontPanelCard(system.features)
                        }
                    } else {
                        Text("System details haven't loaded yet.")
                    }
                    updatesCard(state)
                    portsCard(state)
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
    }

    // MARK: Cards

    func systemCard(_ system: SystemInfo) -> some View {
        let d = system.details
        return Card("System") {
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

    func featuresCard(_ f: SystemFeatures) -> some View {
        Card("Features") {
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

    func frontPanelCard(_ f: SystemFeatures) -> some View {
        Card("Front Panel") {
            if let level = f.backlight {
                HStack {
                    Text("Backlight").foregroundColor(Color.gray).frame(width: 190, alignment: .leading)
                    Picker(of: BacklightOption.allCases, selection: backlightBinding(current: level))
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .disabled(model.backlightPending != nil)
                }
            }
            if let on = f.statusLEDOn {
                HStack {
                    Text("Status LED").foregroundColor(Color.gray).frame(width: 190, alignment: .leading)
                    Toggle("", isOn: statusLEDBinding(current: on))
                        .toggleStyle(.switch)
                        .disabled(model.statusLEDPending != nil)
                }
            }
            if let error = model.frontPanelError {
                Text(error).foregroundColor(Color.system(.red))
            }
        }
    }

    func updatesCard(_ state: MatrixState) -> some View {
        Card("Firmware Updates") {
            if state.updates.isEmpty {
                Text("No updates detected.")
            } else {
                ForEach(state.updates) { update in
                    HStack {
                        Text(update.name)
                        if let version = update.firmwareVersion {
                            Text("(current \(version))").foregroundColor(Color.gray)
                        }
                        Spacer()
                        Text("Update available").foregroundColor(Color.system(.orange))
                    }
                    .onTapGesture { model.openPort(PortSelection(mode: .output, bay: update.bay)) }
                }
            }
        }
    }

    /// Plain rows rather than SwiftCrossUI's `Table`: buttons inside table cells never receive
    /// clicks (the native table swallows them) and `Table` has no row selection, so rows couldn't
    /// open the detail sheet. Whole-row tap gestures work.
    func portsCard(_ state: MatrixState) -> some View {
        let rows = portRows(state)
        return Card("Ports") {
            if rows.isEmpty {
                Text("No ports discovered yet.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    portRow("Port", "Name", "Type", "Status", "Source", header: true)
                    ForEach(rows) { row in
                        portRow(row.port, row.name, row.type, nil, row.source, header: false, status: row.status, update: row.update)
                            .onTapGesture { model.openPort(row.selection) }
                    }
                }
                Text("Click a port to see details.").font(.caption)
            }
        }
    }

    @ViewBuilder
    func portRowCell(_ text: String, width: Int, header: Bool) -> some View {
        if header {
            Text(text).foregroundColor(Color.gray).frame(width: width, alignment: .leading)
        } else {
            Text(text).frame(width: width, alignment: .leading)
        }
    }

    func portRow(
        _ port: String, _ name: String, _ type: String, _ statusLabel: String?, _ source: String,
        header: Bool, status: PortStatus? = nil, update: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            portRowCell(port, width: 90, header: header)
            portRowCell(name, width: 150, header: header)
            portRowCell(type, width: 100, header: header)
            if let status {
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(update ? "\(status.label) · update" : status.label)
                }
                .frame(width: 170, alignment: .leading)
            } else {
                portRowCell(statusLabel ?? "", width: 170, header: header)
            }
            portRowCell(source, width: 140, header: header)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    // MARK: Helpers

    func portRows(_ state: MatrixState) -> [PortRow] {
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

    func backlightBinding(current: BacklightLevel) -> Binding<BacklightOption?> {
        Binding(
            get: { BacklightOption(model.backlightPending ?? current) },
            set: { if let option = $0, option.level != (model.backlightPending ?? current) { model.setBacklight(option.level) } }
        )
    }

    func statusLEDBinding(current: Bool) -> Binding<Bool> {
        Binding(
            get: { model.statusLEDPending ?? current },
            set: { model.setStatusLED(on: $0) }
        )
    }

    func formatMs(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\((minutes * 10).rounded() / 10)m" }
        return "\((minutes / 60 * 10).rounded() / 10)h"
    }
}
