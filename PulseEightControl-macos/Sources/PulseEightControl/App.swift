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
                .task { await model.start() }
                // Set on the app rather than with `.preferredColorScheme`: that modifier can't go back to
                // "follow the system" cleanly. Choosing System left the window half redrawn in the old
                // scheme until it next took focus.
                .onChange(of: model.settings.appearance, initial: true) { _, appearance in
                    NSApp.appearance = appearance.nsAppearance
                }
        }
        .defaultSize(width: 900, height: 660)
        .commands { AppCommands(model: model, updater: updater) }

        Settings {
            SettingsView(model: model, updater: updater)
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
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
