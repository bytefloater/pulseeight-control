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
        .task {
            if model.phase == .notConfigured { openConnections() }
        }
        .environment(\.openMatrixSettings, { openConnections() })
    }

    private func openConnections() {
        model.settingsPane = .connections
        openSettings()
    }

    @ViewBuilder
    private var content: some View {
        if model.phase != .connected {
            ConnectionPanel(model: model)
        } else {
            switch model.page {
            case .routing: RoutingPage(model: model)
            case .hardware: HardwarePage(model: model)
            }
        }
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
