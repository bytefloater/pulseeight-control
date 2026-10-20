import PulseEightCore
import SwiftUI

/// The Settings window (Cmd-,): a sidebar of panes over grouped forms, like System Settings.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: UpdaterModel
    /// Which matrix's popover is open.
    @State private var editing: MatrixEditTarget?

    private var strings: Strings { model.strings }

    var body: some View {
        NavigationSplitView {
            List(selection: paneBinding) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title(strings), systemImage: pane.symbol).tag(pane)
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
            .navigationTitle(model.settingsPane.title(strings))
        }
        .frame(width: 720, height: 520)
    }

    // MARK: Panes

    @ViewBuilder
    private var connectionsPane: some View {
        Section {
            if model.matrices.isEmpty {
                Text(strings.text(.settingsConnectionsNone))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.matrices) { matrix in
                MatrixRow(model: model, matrix: matrix, editing: $editing)
            }
            HStack {
                Spacer()
                Button(strings.text(.settingsConnectionsAdd)) { edit(.new) }
                    .popover(isPresented: isEditing(.new), arrowEdge: .bottom) {
                        MatrixEditor(model: model, close: { editing = nil })
                    }
            }
        } header: {
            Text(strings.text(.settingsConnections))
        } footer: {
            Text(strings.text(.settingsConnectionsCaption))
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
        Section(strings.text(.settingsTheme)) {
            ControlRow(strings.text(.settingsAppearance)) {
                Picker(strings.text(.settingsAppearance), selection: appearanceBinding) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title(strings)).tag($0) }
                }
                .fixedSize()
            }
        }
        Section(strings.text(.settingsLanguage)) {
            ControlRow(strings.text(.settingsLanguage)) {
                Picker(strings.text(.settingsLanguage), selection: languageBinding) {
                    Text(strings.text(.languageSystem)).tag(Languages.systemSetting)
                    ForEach(Languages.all, id: \.code) { Text($0.nativeName).tag($0.code) }
                }
                .fixedSize()
            }
        }
        Section(strings.text(.settingsWindow)) {
            ControlRow(strings.text(.settingsHighlight)) { Toggle(strings.text(.settingsHighlight), isOn: highlightBinding) }
            ControlRow(strings.text(.settingsStatusBar)) { Toggle(strings.text(.settingsStatusBar), isOn: statusBarBinding) }
        }
    }

    @ViewBuilder
    private var updatesPane: some View {
        Section(strings.text(.aboutVersion)) {
            LabeledContent(strings.text(.appTitle)) { Text(AppVersion.description(strings: strings)).textSelection(.enabled) }
        }
        if updater.isAvailable {
            Section {
                ControlRow(strings.text(.settingsUpdatesAuto)) {
                    Toggle(strings.text(.settingsUpdatesAuto), isOn: $updater.automaticallyChecks)
                }
                ControlRow(strings.text(.settingsUpdatesPrereleases)) {
                    Toggle(strings.text(.settingsUpdatesPrereleases), isOn: prereleasesBinding)
                }
                LabeledContent(strings.text(.settingsUpdatesLastCheckedLabel)) {
                    if let date = updater.lastChecked {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text(strings.text(.commonNever)).foregroundStyle(.secondary)
                    }
                }
                ControlRow(strings.text(.settingsUpdatesCheckNow)) {
                    Button(strings.text(.settingsUpdatesCheckNowButton)) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text(strings.text(.settingsUpdates))
            } footer: {
                Text(strings.text(.settingsUpdatesFooter) + " " + strings.text(.settingsUpdatesPrereleasesCaption))
            }
        } else {
            Section {
                Text(strings.text(.settingsUpdatesUnavailable))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bindings

    private var paneBinding: Binding<SettingsPane?> {
        Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })
    }

    /// Unset follows the installed build (a beta keeps getting betas); once chosen it is what was chosen.
    private var prereleasesBinding: Binding<Bool> {
        Binding(
            get: { model.settings.updatePrereleases ?? updater.buildIsPrerelease },
            set: { model.setUpdatePrereleases($0) })
    }

    /// The saved choice: a language, or "system". A saved language that is no longer offered shows as following the system.
    private var languageBinding: Binding<String> {
        Binding(
            get: { Languages.all.contains { $0.code == model.settings.language } ? model.settings.language : Languages.systemSetting },
            set: { model.setLanguage($0) })
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
