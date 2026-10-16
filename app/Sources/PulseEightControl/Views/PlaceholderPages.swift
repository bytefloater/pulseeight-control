import PulseEightKit
import SwiftCrossUI

/// M4 replaces this with the system cards, ports table and front panel controls.
struct HardwarePage: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware").font(.title2)
            Text("System info, firmware and front panel controls arrive in a later milestone.").font(.caption)
            if let system = model.state?.system {
                Text("\(system.details.model)  ·  firmware \(system.details.version)  ·  serial \(system.details.serial)")
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
