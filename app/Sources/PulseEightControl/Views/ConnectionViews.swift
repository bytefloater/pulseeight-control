import PulseEightKit
import SwiftCrossUI

/// Window footer: one line of connection state.
struct ConnectionFooter: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .foregroundColor(dotColor)
                .frame(width: 10, height: 10)
            Text(label)
            Spacer()
            if let count = model.state?.updates.count, count > 0 {
                Button("\(count) firmware update\(count == 1 ? "" : "s") available") { model.page = .hardware }
            }
            if model.adminConfigured {
                Text("Admin enabled")
            }
        }
        .padding(8)
    }

    var dotColor: Color {
        switch model.phase {
        case .connected: Color.system(.green)
        case .connecting: Color.system(.orange)
        case .notConfigured: Color.gray
        case .disconnected: Color.system(.red)
        }
    }

    var label: String {
        switch model.phase {
        case .connected: "Connected to \(model.hostLabel)"
        case .connecting: "Connecting to \(model.hostLabel)…"
        case .notConfigured: "Not configured"
        case .disconnected: "Not connected to \(model.hostLabel)"
        }
    }
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
