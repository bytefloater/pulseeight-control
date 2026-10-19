import PulseEightCore
import SwiftUI

/// The Settings window (Cmd-,): a sidebar of panes over grouped forms, like System Settings.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: UpdaterModel

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
                case .matrix: matrixPane
                case .admin: adminPane
                case .appearance: appearancePane
                case .updates: updatesPane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.settingsPane.title)
        }
        .frame(width: 720, height: 520)
        .onAppear { model.resetDraft() }
    }

    // MARK: Panes

    @ViewBuilder
    private var matrixPane: some View {
        Section("Connection") {
            TextField("Host", text: $model.draft.host, prompt: Text("192.168.1.150"))
                .multilineTextAlignment(.trailing)
            LabeledContent {
                Button(model.discovering ? "Looking…" : "Find Matrix") { Task { await model.findMatrixForSettings() } }
                    .disabled(model.discovering)
            } label: {
                Text("Don't know the address?")
                    .foregroundStyle(.secondary)
            }
            TextField("Port", text: $model.draft.port, prompt: Text("80"))
                .multilineTextAlignment(.trailing)
            TextField("Timeout (seconds)", text: $model.draft.timeout, prompt: Text("10"))
                .multilineTextAlignment(.trailing)
            TextField("Poll interval (seconds)", text: $model.draft.pollInterval, prompt: Text("5"))
                .multilineTextAlignment(.trailing)
            TextField("Detail poll interval (seconds)", text: $model.draft.detailPollInterval, prompt: Text("20"))
                .multilineTextAlignment(.trailing)
            applyRow
        }
    }

    @ViewBuilder
    private var adminPane: some View {
        Section {
            SecureField(
                "Password",
                text: $model.draft.adminPassword,
                prompt: Text(model.adminConfigured ? "Saved" : "Optional")
            )
            .multilineTextAlignment(.trailing)
            if model.adminConfigured {
                Button("Remove Saved Password", role: .destructive) { model.removeAdminPassword() }
            }
            applyRow
        } header: {
            Text("Admin Password")
        } footer: {
            Text("Needed to rename ports and change EDID or front panel settings. It is stored in the system's secure storage, never in the settings file.")
        }
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

    /// Message (if any) and the Apply button, as the last row of a group.
    private var applyRow: some View {
        HStack {
            if let message = model.settingsMessage {
                Text(message.text).foregroundStyle(message.isError ? Color.red : Color.secondary)
            }
            Spacer()
            Button("Apply") { model.saveSettings() }
        }
    }

    // MARK: Bindings

    private var paneBinding: Binding<SettingsPane?> {
        Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })
    }

    private var appearanceBinding: Binding<Appearance> {
        Binding(get: { model.draft.appearance }, set: { model.setAppearance($0) })
    }

    private var highlightBinding: Binding<Bool> {
        Binding(get: { model.settings.highlightGrid }, set: { model.setHighlightGrid($0) })
    }

    private var statusBarBinding: Binding<Bool> {
        Binding(get: { model.settings.showStatusBar }, set: { model.setShowStatusBar($0) })
    }
}
