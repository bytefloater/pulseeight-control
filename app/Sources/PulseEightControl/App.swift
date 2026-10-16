import DefaultBackend
import SwiftCrossUI

@main
struct PulseEightControlApp: App {
    @State var model = AppModel()

    var body: some Scene {
        WindowGroup("PulseEight Control") {
            RootView(model: model)
                .preferredColorScheme(colorScheme)
                .task { await model.start() }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            // No keyboard shortcuts: SwiftCrossUI 0.10 has no public API for them.
            CommandMenu("Matrix") {
                Button("Refresh") { model.retry() }
                Button("Reconnect") { model.retry() }
                Divider()
                Button("Settings") { model.openSettings() }
            }
        }
    }

    var colorScheme: ColorScheme? {
        switch model.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
