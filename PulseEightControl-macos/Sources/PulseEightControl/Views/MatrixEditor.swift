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

    private var isSelected: Bool { model.selectedMatrixID == matrix.id }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.selectMatrix(id: matrix.id) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "The matrix being shown" : "Show this matrix")

            VStack(alignment: .leading, spacing: 2) {
                Text(matrix.displayName)
                if matrix.displayName != matrix.address {
                    Text(matrix.address).font(.callout).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectMatrix(id: matrix.id) }

            Spacer()

            Button("Edit…") {
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

    private var isNew: Bool { model.matrixDraft.id == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Matrix" : "Edit Matrix").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Name") {
                    TextField("Name", text: $model.matrixDraft.name, prompt: Text("Lounge"))
                }
                row("Host") {
                    HStack {
                        TextField("Host", text: $model.matrixDraft.host, prompt: Text("192.168.1.150"))
                        Button(model.discovering ? "Looking…" : "Find") { Task { await model.findMatrixForDraft() } }
                            .disabled(model.discovering)
                            .help("Ask gotomymatrix.com which matrix is on this network")
                    }
                }
                row("Port") { TextField("Port", text: $model.matrixDraft.port, prompt: Text("80")) }
                row("Timeout (s)") { TextField("Timeout", text: $model.matrixDraft.timeout, prompt: Text("10")) }
                row("Poll interval (s)") { TextField("Poll interval", text: $model.matrixDraft.pollInterval, prompt: Text("5")) }
                row("Detail poll (s)") { TextField("Detail poll interval", text: $model.matrixDraft.detailPollInterval, prompt: Text("20")) }
                row("Admin password") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(
                            "Admin password", text: $model.matrixDraft.adminPassword,
                            prompt: Text(model.matrixDraft.adminPasswordSaved && !model.matrixDraft.clearAdminPassword ? "Saved" : "Optional"))
                        if model.matrixDraft.adminPasswordSaved {
                            Toggle("Remove the saved password", isOn: $model.matrixDraft.clearAdminPassword)
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
                        Button("Remove", role: .destructive) {
                            model.removeMatrix(id: id)
                            close()
                        }
                        Button("Keep") { confirmingRemove = false }
                    } else {
                        Button("Remove Matrix…", role: .destructive) { confirmingRemove = true }
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
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
