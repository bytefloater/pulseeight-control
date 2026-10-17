import AppKit
import PulseEightCore
import SwiftUI

@main
struct PulseEightControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var updater = UpdaterModel()

    var body: some Scene {
        // A single window (not a WindowGroup), so there is no File > New Window.
        Window("PulseEight Control", id: "main") {
            RootView(model: model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { await model.start() }
        }
        .defaultSize(width: 900, height: 660)
        .commands { AppCommands(model: model, updater: updater) }

        Settings {
            SettingsView(model: model, updater: updater)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An unbundled executable starts as a background process; make it a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Appearance {
    /// nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
