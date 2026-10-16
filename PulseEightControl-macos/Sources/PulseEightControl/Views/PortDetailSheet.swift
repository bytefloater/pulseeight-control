import PulseEightKit
import SwiftCrossUI

struct EdidOption: Equatable, CustomStringConvertible {
    var id: Int
    var description: String
}

/// Port details, plus rename and (for inputs) EDID profile when an admin password is set.
struct PortDetailSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = model.selectedPort, let state = model.state {
                content(selection, state)
            }
            HStack {
                Spacer()
                Button("Done") { model.selectedPort = nil }
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    @ViewBuilder
    func content(_ selection: PortSelection, _ state: MatrixState) -> some View {
        let port = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }
        Text(port?.name ?? "\(selection.mode.rawValue) \(selection.bay + 1)").font(.title2)
        Text("\(selection.mode.rawValue) \(selection.bay + 1)").font(.caption)

        if model.adminConfigured {
            editForm(selection, state)
        } else {
            Text("Set an admin password in Settings to rename ports or change EDID.").font(.caption)
        }

        switch selection.mode {
        case .input:
            if let details = state.inputDetails[selection.bay] {
                let base = details.base
                KeyValueRows(pairs: [
                    ("Status", base.statusDescription),
                    ("Type", base.type),
                    ("Has signal", base.hasSignal.map(yesNo)),
                    ("Signal", base.videoSignal),
                    ("Source type", base.signal),
                    ("HDCP", details.hdcp.map(String.init)),
                ])
            } else {
                Text("Details haven't loaded yet.")
            }
        case .output:
            if let details = state.outputDetails[selection.bay] {
                let base = details.base
                KeyValueRows(pairs: [
                    ("Status", base.statusDescription),
                    ("Type", base.type),
                    ("Has signal", base.hasSignal.map(yesNo)),
                    ("Signal", base.videoSignal ?? base.signal),
                    ("Routed from input", port?.receiveFrom.map { sourceName($0, state) }),
                    ("Link status", details.linkStatus),
                    ("Cable length (est.)", details.estimatedCableLength.flatMap { $0 > 0 ? "\($0) m" : nil }),
                    ("Sink vendor", details.vendor),
                    ("Sink model", details.monitorName),
                    ("PoE", details.poe.map { $0 ? "On" : "Off" }),
                    ("Firmware version", firmwareText(details)),
                    ("TMDS", details.linkQuality.map { String($0.tmds) }),
                    ("Total BER", details.linkQuality.map { String($0.totalBER) }),
                ])
            } else {
                Text("Details haven't loaded yet.")
            }
        }
    }

    @ViewBuilder
    func editForm(_ selection: PortSelection, _ state: MatrixState) -> some View {
        FormRow("Name") {
            TextField("Up to \(AdminClient.maxNameLength) characters", text: $model.portEdit.name)
                .frame(width: 200)
        }
        if selection.mode == .input {
            FormRow("EDID profile") {
                Picker(of: edidOptions(state), selection: edidBinding(state))
                    .pickerStyle(.menu)
            }
        }
        FormRow("") {
            Button(model.portEdit.saving ? "Saving…" : "Save") { model.savePortEdit() }
                .disabled(model.portEdit.saving)
        }
        if let error = model.portEdit.error {
            FormRow("") { Text(error).foregroundColor(Color.system(.red)) }
        }
        Divider()
    }

    // MARK: Helpers

    func edidOptions(_ state: MatrixState) -> [EdidOption] {
        var options = EdidProfiles.build(scrambling: state.system?.features.video.scrambling ?? false, ports: state.ports)
            .map { EdidOption(id: $0.id, description: $0.name) }
        // A profile the matrix reports but we have no name for, e.g. one set from its own web UI.
        if let current = model.portEdit.edidProfile, !options.contains(where: { $0.id == current }) {
            options.append(EdidOption(id: current, description: "Custom Profile (\(current))"))
        }
        return options
    }

    func edidBinding(_ state: MatrixState) -> Binding<EdidOption?> {
        Binding(
            get: { edidOptions(state).first { $0.id == model.portEdit.edidProfile } },
            set: { if let option = $0 { model.portEdit.edidProfile = option.id } }
        )
    }

    func firmwareText(_ details: OutputPortDetails) -> String? {
        guard let version = details.firmwareVersion, !version.isEmpty else { return nil }
        return "\(version)  (\(details.firmwareVersionAvailable == true ? "update available" : "up to date"))"
    }

    func sourceName(_ bay: Int, _ state: MatrixState) -> String {
        state.inputs.first { $0.bay == bay }?.name ?? "Input \(bay + 1)"
    }
}
