import SwiftCrossUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(Page.allCases, id: \.self, selection: $model.page)
                Spacer()
            }
            .padding(8)
        } detail: {
            VStack(spacing: 0) {
                content
                Divider()
                ConnectionFooter(model: model)
            }
        }
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
}
