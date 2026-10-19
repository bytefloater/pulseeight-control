import PulseEightKit
import SwiftUI

struct EdidOption: Equatable {
    var id: Int
    var name: String
}

/// Port details, plus rename and (for inputs) EDID profile when an admin password is set.
struct PortDetailSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let selection = model.selectedPort, let state = model.state {
                Form { content(selection, state) }
                    .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Done") { model.selectedPort = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private func content(_ selection: PortSelection, _ state: MatrixState) -> some View {
        let port = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }
        Section {
            let label = "\(selection.mode.rawValue) \(selection.bay + 1)"
            Text(port?.name ?? label).font(.title2)
            if let name = port?.name, name != label {
                Text(label).foregroundStyle(.secondary)
            }
        }

        if model.adminConfigured {
            editForm(selection, state)
        } else {
            Section {
                Text("Set an admin password in Settings to rename ports or change EDID.")
                    .foregroundStyle(.secondary)
            }
        }

        Section("Details") {
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
                    Text("Details haven't loaded yet.").foregroundStyle(.secondary)
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
                    Text("Details haven't loaded yet.").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func editForm(_ selection: PortSelection, _ state: MatrixState) -> some View {
        Section {
            TextField("Name", text: $model.portEdit.name, prompt: Text("Up to \(AdminClient.maxNameLength) characters"))
                .onSubmit { model.savePortEdit() }
            if selection.mode == .input {
                ControlRow("EDID profile") {
                    Picker("EDID profile", selection: $model.portEdit.edidProfile) {
                        ForEach(edidOptions(state), id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    .fixedSize()
                }
            }
            HStack {
                if let error = model.portEdit.error {
                    Text(error).foregroundStyle(.red)
                }
                Spacer()
                Button(model.portEdit.saving ? "Saving…" : "Save") { model.savePortEdit() }
                    .disabled(model.portEdit.saving)
            }
        }
    }

    // MARK: Helpers

    private func edidOptions(_ state: MatrixState) -> [EdidOption] {
        var options = EdidProfiles.build(scrambling: state.system?.features.video.scrambling ?? false, ports: state.ports)
            .map { EdidOption(id: $0.id, name: $0.name) }
        // A profile the matrix reports but we have no name for, e.g. one set from its own web UI.
        if let current = model.portEdit.edidProfile, !options.contains(where: { $0.id == current }) {
            options.append(EdidOption(id: current, name: "Custom Profile (\(current))"))
        }
        return options
    }

    private func firmwareText(_ details: OutputPortDetails) -> String? {
        guard let version = details.firmwareVersion, !version.isEmpty else { return nil }
        return "\(version)  (\(details.firmwareVersionAvailable == true ? "update available" : "up to date"))"
    }

    private func sourceName(_ bay: Int, _ state: MatrixState) -> String {
        state.inputs.first { $0.bay == bay }?.name ?? "Input \(bay + 1)"
    }
}
