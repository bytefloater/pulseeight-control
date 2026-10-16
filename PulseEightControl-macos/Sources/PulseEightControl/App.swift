import AppKitBackend
import PulseEightCore
import SwiftCrossUI

@main
struct PulseEightControlApp: App {
    @State var model = AppModel()

    // The menu bar is built natively in MacChrome (with real shortcuts), and Settings is a native
    // SwiftUI window (NativeSettings), so this scene is only the main window.
    var body: some Scene {
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
