import PulseEightKit
import SwiftCrossUI

/// Read-only for now; M4 adds rename and EDID.
struct PortDetailSheet: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = model.selectedPort, let state = model.state {
                content(selection, state)
            }
            HStack {
                Spacer()
                Button("Done") { model.selectedPort = nil }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    @ViewBuilder
    func content(_ selection: PortSelection, _ state: MatrixState) -> some View {
        let port = state.ports.first { $0.mode == selection.mode && $0.bay == selection.bay }
        Text(port?.name ?? "\(selection.mode.rawValue) \(selection.bay + 1)").font(.title2)
        Text("\(selection.mode.rawValue) \(selection.bay + 1)").font(.caption)

        switch selection.mode {
        case .input:
            if let details = state.inputDetails[selection.bay] {
                let base = details.base
                rows([
                    ("Status", base.statusDescription),
                    ("Type", base.type),
                    ("Signal", base.videoSignal),
                    ("Source type", base.signal),
                    ("HDCP", details.hdcp.map(String.init)),
                    ("EDID profile", details.edidProfile.map(String.init)),
                ])
            } else {
                Text("Details haven't loaded yet.")
            }
        case .output:
            if let details = state.outputDetails[selection.bay] {
                let base = details.base
                rows([
                    ("Status", base.statusDescription),
                    ("Type", base.type),
                    ("Source", port?.receiveFrom.map { sourceName($0, state) }),
                    ("Display", details.monitorName),
                    ("Link", details.linkStatus),
                    ("PoE", details.poe.map { $0 ? "On" : "Off" }),
                    ("Firmware", details.firmwareVersion),
                    ("Firmware update", details.firmwareVersionAvailable == true ? "Available" : nil),
                ])
            } else {
                Text("Details haven't loaded yet.")
            }
        }
    }

    func sourceName(_ bay: Int, _ state: MatrixState) -> String {
        state.inputs.first { $0.bay == bay }?.name ?? "Input \(bay + 1)"
    }

    /// Skips rows the device didn't report, like the old web UI's key/value cards.
    func rows(_ pairs: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pairs.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }, id: \.0) { pair in
                HStack(alignment: .top) {
                    Text(pair.0).frame(width: 120, alignment: .leading)
                    Text(pair.1)
                }
            }
        }
    }
}
