import SwiftCrossUI

struct RootView: View {
    @Bindable var model: AppModel

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
                .task { await MacChrome.shared.install(model: model) }
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
        #endif
    }

    @ViewBuilder
    var content: some View {
        let page = model.page ?? .routing
        if page == .settings {
            SettingsPage(model: model)
        } else if model.phase != .connected {
            ConnectionPanel(model: model)
        } else if page == .routing {
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
