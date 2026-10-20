import PulseEightCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var strings: Strings { model.strings }

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
                Picker(strings.text(.navPage), selection: $model.page) {
                    ForEach(Page.allCases) { page in
                        Label(page.title(strings), systemImage: page.symbol).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
        }
        .sheet(isPresented: sheetBinding) {
            PortDetailSheet(model: model)
        }
        .alert(strings.text(.maintenanceConfirmTitle, model.hostLabel), isPresented: $model.confirmingRestart) {
            Button(strings.text(.maintenanceConfirmButton), role: .destructive) { model.restartMatrix() }
            Button(strings.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(strings.text(.maintenanceConfirmBody))
        }
        .alert(strings.text(.maintenanceError), isPresented: restartErrorBinding) {
            Button(strings.text(.commonOK)) {}
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

    private var strings: Strings { model.strings }

    var body: some View {
        Menu {
            Picker(strings.text(.matrixSwitch), selection: selection) {
                ForEach(model.matrices) { matrix in
                    Text(matrix.displayName).tag(Optional(matrix.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(strings.text(.matrixManage), action: openConnections)
        } label: {
            Label(model.settings.selectedMatrix?.displayName ?? strings.text(.matrixSwitch), systemImage: "rectangle.connected.to.line.below")
        }
        .help(strings.text(.matrixChoose))
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedMatrixID },
            set: { if let id = $0 { model.selectMatrix(id: id) } })
    }
}
