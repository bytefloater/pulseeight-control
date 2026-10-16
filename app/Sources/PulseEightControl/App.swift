import DefaultBackend
import SwiftCrossUI

@main
struct PulseEightControlApp: App {
    @State var model = AppModel()

    var body: some Scene {
        #if os(macOS)
            // The menu bar is built natively in MacChrome (with real shortcuts).
            mainWindow
            settingsWindow
        #else
            mainWindow.commands {
                // No keyboard shortcuts: SwiftCrossUI 0.10 has no public API for them.
                CommandMenu("Matrix") {
                    Button("Refresh") { model.retry() }
                    Divider()
                    Button("Settings") { model.openSettings() }
                }
            }
            settingsWindow
        #endif
    }

    var settingsWindow: some Scene {
        Window("Settings", id: "settings") {
            SettingsWindow(model: model)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: SettingsWindow.width, height: SettingsWindow.height)
    }

    var mainWindow: some Scene {
        WindowGroup("PulseEight Control") {
            RootView(model: model)
                .preferredColorScheme(colorScheme)
                .task { await model.start() }
        }
        .defaultSize(width: 900, height: 660)
    }

    var colorScheme: ColorScheme? {
        switch model.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
