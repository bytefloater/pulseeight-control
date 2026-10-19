import PulseEightCore
import SwiftUI

/// The Settings window (Cmd-,): a sidebar of panes over grouped forms, like System Settings.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: UpdaterModel
    /// Which matrix's popover is open.
    @State private var editing: MatrixEditTarget?

    var body: some View {
        NavigationSplitView {
            List(selection: paneBinding) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch model.settingsPane {
                case .connections: connectionsPane
                case .appearance: appearancePane
                case .updates: updatesPane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.settingsPane.title)
        }
        .frame(width: 720, height: 520)
    }

    // MARK: Panes

    @ViewBuilder
    private var connectionsPane: some View {
        Section {
            if model.matrices.isEmpty {
                Text("No matrices yet. Add one to get started.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.matrices) { matrix in
                MatrixRow(model: model, matrix: matrix, editing: $editing)
            }
            HStack {
                Spacer()
                Button("Add Matrix…") { edit(.new) }
                    .popover(isPresented: isEditing(.new), arrowEdge: .bottom) {
                        MatrixEditor(model: model, close: { editing = nil })
                    }
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("Pick the matrix to control. Each one has its own address, timings and admin password; the admin password is needed to rename ports and change EDID or front panel settings, and is kept in the system's secure storage.")
        }
    }

    private func edit(_ target: MatrixEditTarget) {
        model.beginEditingMatrix(target.id)
        editing = target
    }

    private func isEditing(_ target: MatrixEditTarget) -> Binding<Bool> {
        Binding(get: { editing == target }, set: { if !$0, editing == target { editing = nil } })
    }

    @ViewBuilder
    private var appearancePane: some View {
        Section("Theme") {
            Picker("Appearance", selection: appearanceBinding) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.description).tag($0) }
            }
        }
        Section("Window") {
            Toggle("Highlight row and column", isOn: highlightBinding)
            Toggle("Show status bar", isOn: statusBarBinding)
        }
    }

    @ViewBuilder
    private var updatesPane: some View {
        Section("Version") {
            LabeledContent("PulseEight Control") { Text(AppVersion.description()).textSelection(.enabled) }
        }
        if updater.isAvailable {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                LabeledContent("Last checked") {
                    if let date = updater.lastChecked {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("Updates are signed and checked before they are installed.")
            }
        } else {
            Section {
                Text("Updates are delivered to the packaged app. This is a development build, so there is nothing to check.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bindings

    private var paneBinding: Binding<SettingsPane?> {
        Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })
    }

    private var appearanceBinding: Binding<Appearance> {
        Binding(get: { model.settings.appearance }, set: { model.setAppearance($0) })
    }

    private var highlightBinding: Binding<Bool> {
        Binding(get: { model.settings.highlightGrid }, set: { model.setHighlightGrid($0) })
    }

    private var statusBarBinding: Binding<Bool> {
        Binding(get: { model.settings.showStatusBar }, set: { model.setShowStatusBar($0) })
    }
}
