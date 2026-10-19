import PulseEightKit
import SwiftUI

/// Bottom status bar: connection first, then whatever else is worth knowing.
struct StatusBar: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                ForEach(Array(statusItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().frame(height: 14) }
                    itemView(item)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func itemView(_ item: StatusItem) -> some View {
        switch item.kind {
        case .connection:
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text(model.connectionSummary)
            }
        case .updates:
            Button(item.text) { model.page = .hardware }
                .buttonStyle(.link)
        case .text:
            Text(item.text)
        }
    }

    private var dotColor: Color {
        switch model.displayPhase {
        case .connected: .green
        case .connecting: .orange
        case .notConfigured: .gray
        case .disconnected: .red
        }
    }

    private var statusItems: [StatusItem] {
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

/// Replaces the page while the matrix is unreachable.
struct ConnectionPanel: View {
    var model: AppModel
    @Environment(\.openMatrixSettings) private var openSettings

    var body: some View {
        Group {
            switch model.displayPhase {
            case .notConfigured:
                ContentUnavailableView {
                    Label("No matrix configured", systemImage: "network.slash")
                } description: {
                    Text("Find your NeoMatrix on this network, or enter its IP address in Settings.")
                    if let error = model.discoveryError { Text(error).foregroundStyle(.red) }
                } actions: {
                    Button(model.discovering ? "Looking…" : "Find Matrix") { Task { await model.findAndConnect() } }
                        .disabled(model.discovering)
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings") { openSettings() }
                }
            case .connecting:
                VStack(spacing: 8) {
                    ProgressView("Connecting to \(model.hostLabel)…")
                    if model.localNetwork.state == .asking {
                        Text("macOS is asking whether PulseEight Control may use the local network. Choose Allow.")
                            .foregroundStyle(.secondary)
                    }
                }
            case .disconnected(let reason):
                ContentUnavailableView {
                    Label("Can't reach the matrix", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("No response from \(model.hostLabel).")
                    if let reason { Text(reason) }
                } actions: {
                    Button(model.retrying ? "Retrying…" : "Retry now") { model.retry() }
                        .disabled(model.retrying)
                    Button("Open Settings") { openSettings() }
                }
            case .connected:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
