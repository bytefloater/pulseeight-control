import AppKit
import PulseEightCore
import PulseEightKit
import SwiftUI

/// The menu bar. Settings… (Cmd-,) comes from the `Settings` scene; Edit and Window are standard.
struct AppCommands: Commands {
    var model: AppModel
    var updater: UpdaterModel

    private var features: SystemFeatures? { model.state?.system?.features }
    private var hasHost: Bool { model.settings.matrix.host?.isEmpty == false }

    private var matrixAddress: String? {
        let config = model.settings.matrix
        guard let host = config.host, !host.isEmpty else { return nil }
        return config.port == 80 ? host : "\(host):\(config.port)"
    }

    var body: some Commands {
        // Under "About PulseEight Control", where Mac apps keep it. Absent from development runs.
        if updater.isAvailable {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Matrix Web Interface") { openWebInterface() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!hasHost)
            Button("Show Settings Folder in Finder") { showSettingsFolder() }
        }

        CommandGroup(before: .toolbar) {
            Button("Routing") { model.page = .routing }
                .keyboardShortcut("1")
            Button("Hardware") { model.page = .hardware }
                .keyboardShortcut("2")
            Divider()
            Toggle("Highlight Row and Column", isOn: Binding(
                get: { model.settings.highlightGrid }, set: { model.setHighlightGrid($0) }
            ))
            Toggle("Show Status Bar", isOn: Binding(
                get: { model.settings.showStatusBar }, set: { model.setShowStatusBar($0) }
            ))
            .keyboardShortcut("/")
            Divider()
        }

        CommandMenu("Matrix") {
            if model.matrices.count > 1 {
                Picker("Switch Matrix", selection: Binding(
                    get: { model.selectedMatrixID },
                    set: { if let id = $0 { model.selectMatrix(id: id) } }
                )) {
                    ForEach(model.matrices) { matrix in
                        Text(matrix.displayName).tag(Optional(matrix.id))
                    }
                }
                Divider()
            }
            Button("Refresh Now") { model.retry() }
                .keyboardShortcut("r")
                .disabled(!hasHost)
            Button("Reconnect") { model.reconnect() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!hasHost)
            Divider()
            Menu("Backlight") {
                backlightToggle("Off", .off)
                backlightToggle("Dim", .low)
                backlightToggle("Bright", .high)
            }
            Toggle("Status LED", isOn: Binding(
                get: { features?.statusLEDOn == true },
                set: { model.setStatusLED(on: $0) }
            ))
            .disabled(features?.statusLED == nil || !model.adminConfigured)
            Divider()
            Button("Copy Matrix Address") { copyAddress() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(matrixAddress == nil)
        }
    }

    private func backlightToggle(_ title: String, _ level: BacklightLevel) -> some View {
        Toggle(title, isOn: Binding(
            get: { features?.backlight == level },
            set: { if $0 { model.setBacklight(level) } }
        ))
        .disabled(features?.backlightLED == nil || !model.adminConfigured)
    }

    private func openWebInterface() {
        guard let address = matrixAddress, let url = URL(string: "http://\(address)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyAddress() {
        guard let address = matrixAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    private func showSettingsFolder() {
        try? FileManager.default.createDirectory(at: ConfigPaths.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ConfigPaths.directory)
    }
}
