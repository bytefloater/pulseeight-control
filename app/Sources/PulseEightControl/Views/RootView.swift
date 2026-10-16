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

    /// Both pages stay mounted and the inactive one is collapsed to nothing.
    /// Creating a page means building and attaching hundreds of AppKit views, which made every tab
    /// switch take a noticeable fraction of a second; switching visibility is just a layout change.
    @ViewBuilder
    var content: some View {
        if model.phase != .connected {
            ConnectionPanel(model: model)
        } else {
            let page = model.page ?? .routing
            ZStack(alignment: .topLeading) {
                RoutingPage(model: model).shown(page == .routing)
                HardwarePage(model: model).shown(page == .hardware)
            }
        }
    }

    var sheetBinding: Binding<Bool> {
        Binding(
            get: { model.selectedPort != nil },
            set: { if !$0 { model.selectedPort = nil } }
        )
    }
}

extension View {
    /// Keeps the view in the hierarchy but collapses it to nothing. The pages scroll inside an
    /// NSScrollView, which clips to its (now zero) bounds, so nothing draws or takes clicks.
    ///
    /// Only the width collapses. Collapsing the height too left the scroll view anchored at the
    /// bottom of its content when it came back, because the vertical geometry changed under it.
    func shown(_ visible: Bool) -> some View {
        frame(width: visible ? nil : Double(0))
    }
}
