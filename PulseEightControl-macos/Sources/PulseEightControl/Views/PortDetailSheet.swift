import PulseEightCore
import PulseEightKit
import SwiftUI

struct EdidOption: Equatable {
    var id: Int
    var name: String
}

/// Port details, plus rename and (for inputs) EDID profile when an admin password is set. The detail rows come from the shared
/// `Presentation.portRows`, so this sheet and the Windows app's say the same thing in the same words.
struct PortDetailSheet: View {
    @Bindable var model: AppModel

    private var strings: Strings { model.strings }

    var body: some View {
        VStack(spacing: 0) {
            if let selection = model.selectedPort, let state = model.state {
                Form { content(selection, state) }
                    .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button(strings.text(.commonDone)) { model.selectedPort = nil }
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
            let label = strings.text(.portDialogTitle, Presentation.modeName(selection.mode, strings), selection.bay + 1)
            Text(port?.name ?? label).font(.title2)
            if let name = port?.name, name != label {
                Text(label).foregroundStyle(.secondary)
            }
        }

        if model.adminConfigured {
            editForm(selection, state)
        } else {
            Section {
                Text(strings.text(.portDialogNeedAdmin))
                    .foregroundStyle(.secondary)
            }
        }

        Section(strings.text(.portDialogDetails)) {
            let rows = port.map { Presentation.portRows($0, in: state, strings) } ?? []
            if rows.isEmpty {
                Text(strings.text(.portDialogDetailsPending)).foregroundStyle(.secondary)
            } else {
                KeyValueRows(pairs: rows.map { ($0.label, $0.value) })
            }
        }
    }

    @ViewBuilder
    private func editForm(_ selection: PortSelection, _ state: MatrixState) -> some View {
        Section {
            TextField(
                strings.text(.portDialogName), text: $model.portEdit.name,
                prompt: Text(strings.text(.portDialogNamePlaceholder, AdminClient.maxNameLength))
            )
            .onSubmit { model.savePortEdit() }
            if selection.mode == .input {
                ControlRow(strings.text(.portDialogEDIDProfile)) {
                    Picker(strings.text(.portDialogEDIDProfile), selection: $model.portEdit.edidProfile) {
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
                Button(model.portEdit.saving ? strings.text(.commonSaving) : strings.text(.commonSave)) { model.savePortEdit() }
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
            options.append(EdidOption(id: current, name: strings.text(.edidCustomProfile, current)))
        }
        return options
    }
}
