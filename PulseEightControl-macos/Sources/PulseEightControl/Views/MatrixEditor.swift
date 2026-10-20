import PulseEightCore
import SwiftUI

/// Which popover is open: the one for a new matrix, or for an existing one.
enum MatrixEditTarget: Hashable {
    case new
    case existing(UUID)

    var id: UUID? {
        if case .existing(let id) = self { id } else { nil }
    }
}

/// One configured matrix in the Connections list: tap to select it, Edit… to change it.
struct MatrixRow: View {
    var model: AppModel
    var matrix: MatrixProfile
    @Binding var editing: MatrixEditTarget?

    private var strings: Strings { model.strings }
    private var isSelected: Bool { model.selectedMatrixID == matrix.id }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.selectMatrix(id: matrix.id) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(isSelected ? strings.text(.settingsConnectionsShown) : strings.text(.settingsConnectionsShow))

            VStack(alignment: .leading, spacing: 2) {
                Text(matrix.displayName)
                if matrix.displayName != matrix.address {
                    Text(matrix.address).font(.callout).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectMatrix(id: matrix.id) }

            Spacer()

            Button(strings.text(.settingsConnectionsEdit)) {
                model.beginEditingMatrix(matrix.id)
                editing = .existing(matrix.id)
            }
            .popover(
                isPresented: Binding(
                    get: { editing == .existing(matrix.id) },
                    set: { if !$0, editing == .existing(matrix.id) { editing = nil } }),
                arrowEdge: .bottom
            ) {
                MatrixEditor(model: model, close: { editing = nil })
            }
        }
    }
}

/// The popover for adding or changing a matrix. Nothing is saved until Save.
struct MatrixEditor: View {
    @Bindable var model: AppModel
    var close: () -> Void
    @State private var confirmingRemove = false

    private var strings: Strings { model.strings }
    private var isNew: Bool { model.matrixDraft.id == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? strings.text(.matrixAddTitle) : strings.text(.matrixEditTitle)).font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                row(strings.text(.matrixName)) {
                    TextField(strings.text(.matrixName), text: $model.matrixDraft.name, prompt: Text(strings.text(.matrixNamePlaceholder)))
                }
                row(strings.text(.settingsAddress)) {
                    HStack {
                        // 192.168.1.150 is an example address, not words: it is the same in every language.
                        TextField(strings.text(.settingsAddress), text: $model.matrixDraft.host, prompt: Text(verbatim: "192.168.1.150"))
                        Button(model.discovering ? strings.text(.matrixFinding) : strings.text(.matrixFind)) { Task { await model.findMatrixForDraft() } }
                            .disabled(model.discovering)
                            .help(strings.text(.matrixFindCaption))
                    }
                }
                row(strings.text(.settingsPort)) { TextField(strings.text(.settingsPort), text: $model.matrixDraft.port, prompt: Text(verbatim: "80")) }
                row(strings.text(.matrixTimeoutSeconds)) { TextField(strings.text(.settingsTimeout), text: $model.matrixDraft.timeout, prompt: Text(verbatim: "10")) }
                row(strings.text(.matrixPollSeconds)) { TextField(strings.text(.settingsRefresh), text: $model.matrixDraft.pollInterval, prompt: Text(verbatim: "5")) }
                row(strings.text(.matrixDetailPollSeconds)) { TextField(strings.text(.settingsDetailInterval), text: $model.matrixDraft.detailPollInterval, prompt: Text(verbatim: "20")) }
                row(strings.text(.matrixAdminPassword)) {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(
                            strings.text(.matrixAdminPassword), text: $model.matrixDraft.adminPassword,
                            prompt: Text(model.matrixDraft.adminPasswordSaved && !model.matrixDraft.clearAdminPassword
                                ? strings.text(.matrixPasswordSaved) : strings.text(.matrixPasswordOptional)))
                        if model.matrixDraft.adminPasswordSaved {
                            Toggle(strings.text(.matrixClearPassword), isOn: $model.matrixDraft.clearAdminPassword)
                                .toggleStyle(.checkbox)
                                .font(.callout)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)

            if let message = model.matrixMessage {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !isNew, let id = model.matrixDraft.id {
                    if confirmingRemove {
                        Button(strings.text(.commonRemove), role: .destructive) {
                            model.removeMatrix(id: id)
                            close()
                        }
                        Button(strings.text(.matrixKeep)) { confirmingRemove = false }
                    } else {
                        Button(strings.text(.matrixRemove), role: .destructive) { confirmingRemove = true }
                    }
                }
                Spacer()
                Button(strings.text(.commonCancel)) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(strings.text(.commonSave)) {
                    if model.saveMatrixDraft() { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
            content()
        }
    }
}
