import SwiftCrossUI

struct RootView: View {
    @Bindable var model: AppModel
    #if !os(macOS)
        @Environment(\.openWindow) var openWindow
    #endif

    var body: some View {
        #if os(macOS)
            // The page switcher is a native preferences-style toolbar (see MacChrome).
            VStack(spacing: 0) {
                content
                if model.settings.showStatusBar { StatusBar(model: model) }
            }
                .sheet(isPresented: sheetBinding) {
                    PortDetailSheet(model: model)
                }
                .onChange(of: model.chromeSignature) { MacChrome.shared.sync() }
                .task {
                    await MacChrome.shared.install(model: model)
                    if model.phase == .notConfigured { model.openSettings() }
                }
        #else
            NavigationSplitView {
                VStack(spacing: 0) {
                    List(Page.allCases, id: \.self, selection: $model.page)
                    Spacer()
                }
                .padding(8)
            } detail: {
                VStack(spacing: 0) {
                    content
                    if model.settings.showStatusBar { StatusBar(model: model) }
                }
            }
            .sheet(isPresented: sheetBinding) {
                PortDetailSheet(model: model)
            }
            .task { registerSettingsWindow() }
        #endif
    }

    #if !os(macOS)

    /// Lets the model (and the macOS menu bar) open the Settings window, and opens it straight
    /// away when there is no matrix to talk to yet.
    func registerSettingsWindow() {
        model.openSettingsWindow = { [openWindow] in openWindow(id: "settings") }
        if model.phase == .notConfigured { model.openSettings() }
    }
    #endif

    /// Only the active page exists. An inactive page is fully unloaded, not hidden: collapsing a
    /// ScrollView doesn't clip it (it keeps its natural width and overflows into the visible page).
    @ViewBuilder
    var content: some View {
        if model.phase != .connected {
            ConnectionPanel(model: model)
        } else if (model.page ?? .routing) == .routing {
            RoutingPage(model: model)
        } else {
            HardwarePage(model: model)
        }
    }

    var sheetBinding: Binding<Bool> {
        Binding(
            get: { model.selectedPort != nil },
            set: { if !$0 { model.selectedPort = nil } }
        )
    }
}
