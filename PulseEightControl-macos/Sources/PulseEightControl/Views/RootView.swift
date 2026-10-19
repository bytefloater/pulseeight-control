import PulseEightCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.settings.showStatusBar { StatusBar(model: model) }
        }
        .frame(minWidth: 560, minHeight: 360)
        .toolbar {
            if !model.matrices.isEmpty {
                ToolbarItem(placement: .navigation) { MatrixPicker(model: model, openConnections: openConnections) }
            }
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $model.page) {
                    ForEach(Page.allCases) { page in
                        Label(page.description, systemImage: page.symbol).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
        }
        .sheet(isPresented: sheetBinding) {
            PortDetailSheet(model: model)
        }
        .alert("Restart \(model.hostLabel)?", isPresented: $model.confirmingRestart) {
            Button("Restart", role: .destructive) { model.restartMatrix() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The matrix goes offline for about a minute and everything routed through it is interrupted: displays lose their picture until it is back. PulseEight Control reconnects by itself.")
        }
        .alert("Couldn't restart the matrix", isPresented: restartErrorBinding) {
            Button("OK") {}
        } message: {
            Text(model.restartError ?? "")
        }
        .task {
            if model.phase == .notConfigured { openConnections() }
        }
        .environment(\.openMatrixSettings, { openConnections() })
    }

    private func openConnections() {
        // (P8_SETTINGS_PANE, a development switch, keeps its own pane.)
        if ProcessInfo.processInfo.environment["P8_SETTINGS_PANE"] == nil { model.settingsPane = .connections }
        openSettings()
    }

    @ViewBuilder
    private var content: some View {
        if model.phase != .connected || model.isRestarting {
            ConnectionPanel(model: model)
        } else {
            switch model.page {
            case .routing: RoutingPage(model: model)
            case .hardware: HardwarePage(model: model)
            }
        }
    }

    private var restartErrorBinding: Binding<Bool> {
        Binding(get: { model.restartError != nil }, set: { if !$0 { model.restartError = nil } })
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { model.selectedPort != nil },
            set: { if !$0 { model.selectedPort = nil } }
        )
    }
}

private struct OpenMatrixSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Lets deep views open Settings without each reading `openSettings`.
    var openMatrixSettings: () -> Void {
        get { self[OpenMatrixSettingsKey.self] }
        set { self[OpenMatrixSettingsKey.self] = newValue }
    }
}

/// Chooses which configured matrix the window shows.
struct MatrixPicker: View {
    @Bindable var model: AppModel
    var openConnections: () -> Void

    var body: some View {
        Menu {
            Picker("Matrix", selection: selection) {
                ForEach(model.matrices) { matrix in
                    Text(matrix.displayName).tag(Optional(matrix.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage Connections…", action: openConnections)
        } label: {
            Label(model.settings.selectedMatrix?.displayName ?? "Matrix", systemImage: "rectangle.connected.to.line.below")
        }
        .help("Choose the matrix to control")
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedMatrixID },
            set: { if let id = $0 { model.selectMatrix(id: id) } })
    }
}
