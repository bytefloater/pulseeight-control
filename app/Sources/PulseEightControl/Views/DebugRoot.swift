import Foundation
import SwiftCrossUI

/// Diagnostic entry point for bisecting backend problems (first used for a WinUI crash).
/// Set `P8_BISECT` to render one piece of the UI in the main window instead of the whole app:
///
///     hello    a single Text
///     scroll   PageScroll around a Text
///     split    a bare NavigationSplitView with a list and a Text
///     status   the status bar
///     panel    the "can't reach the matrix" panel
///     routing  the routing grid
///     hardware the hardware page
///     settings the (non-macOS) settings window content
///
/// Anything else, or unset, shows the normal app.
struct DebugRoot: View {
    @Bindable var model: AppModel

    static var mode: String? { ProcessInfo.processInfo.environment["P8_BISECT"] }

    var body: some View {
        switch Self.mode {
        case "hello":
            Text("Hello from PulseEight Control")
        case "scroll":
            PageScroll { Text("Inside PageScroll") }
        case "split":
            NavigationSplitView {
                List(Page.allCases, id: \.self, selection: $model.page)
            } detail: {
                Text("Detail")
            }
        case "status":
            StatusBar(model: model)
        case "panel":
            ConnectionPanel(model: model)
        case "routing":
            RoutingPage(model: model)
        case "hardware":
            HardwarePage(model: model)
        #if !os(macOS)
            case "settings":
                SettingsWindow(model: model)
        #endif
        default:
            RootView(model: model)
        }
    }
}
