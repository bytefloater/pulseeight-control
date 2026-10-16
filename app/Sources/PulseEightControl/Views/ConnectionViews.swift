import PulseEightKit
import SwiftCrossUI

/// Bottom status bar: connection first, then whatever else is worth knowing, each item
/// separated by a divider.
struct StatusBar: View {
    var model: AppModel

    var body: some View {
        let items = statusItems
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                ForEach(items) { item in
                    if item.id != items.first?.id {
                        Divider().frame(height: 14)
                    }
                    itemView(item)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        // Size must not depend on content: a size change in a child makes SwiftCrossUI re-run
        // every ancestor's body, which would rebuild the routing grid on each poll.
        .frame(maxWidth: .infinity)
        .frame(height: 33)
    }

    @ViewBuilder
    func itemView(_ item: StatusItem) -> some View {
        switch item.kind {
        case .connection:
            HStack(spacing: 6) {
                Circle().foregroundColor(dotColor).frame(width: 9, height: 9)
                Text(model.connectionSummary)
            }
        case .updates:
            Button(item.text) { model.page = .hardware }
        case .text:
            Text(item.text)
        }
    }

    var dotColor: Color {
        switch model.phase {
        case .connected: Color.system(.green)
        case .connecting: Color.system(.orange)
        case .notConfigured: Color.gray
        case .disconnected: Color.system(.red)
        }
    }

    var statusItems: [StatusItem] {
        var items = [StatusItem(id: "connection", kind: .connection, text: "")]
        if model.adminConfigured {
            items.append(StatusItem(id: "admin", kind: .text, text: "Admin enabled"))
        }
        if let count = model.state?.updates.count, count > 0 {
            items.append(StatusItem(id: "updates", kind: .updates, text: "\(count) firmware update\(count == 1 ? "" : "s") available"))
        }
        if let system = model.state?.system {
            items.append(StatusItem(id: "model", kind: .text, text: "\(system.details.model) \(system.details.version)"))
        }
        if let state = model.state, !state.ports.isEmpty {
            items.append(StatusItem(id: "ports", kind: .text, text: "\(state.inputs.count) in, \(state.outputs.count) out"))
        }
        return items
    }
}

struct StatusItem: Identifiable {
    enum Kind { case connection, updates, text }
    var id: String
    var kind: Kind
    var text: String
}

/// Replaces a page's content while the matrix is unreachable. The old web UI used a modal here;
/// SwiftCrossUI has no semantic background colours, so a full-page state reads better in both themes.
struct ConnectionPanel: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .notConfigured:
                ContentUnavailableView {
                    Text("No matrix configured")
                } description: {
                    Text("Enter your NeoMatrix's IP address in Settings to get started.")
                } actions: {
                    Button("Open Settings") { model.openSettings() }
                }
            case .connecting:
                ProgressView("Connecting to \(model.hostLabel)…")
            case .disconnected(let reason):
                ContentUnavailableView {
                    Text("Can't reach the matrix")
                } description: {
                    VStack(spacing: 4) {
                        Text("No response from \(model.hostLabel).")
                        if let reason {
                            Text(reason).font(.caption)
                        }
                    }
                } actions: {
                    HStack {
                        Button(model.retrying ? "Retrying…" : "Retry now") { model.retry() }
                            .disabled(model.retrying)
                        Button("Open Settings") { model.openSettings() }
                    }
                }
            case .connected:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
