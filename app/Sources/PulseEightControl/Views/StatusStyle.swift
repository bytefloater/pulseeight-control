import PulseEightKit
import SwiftCrossUI

extension PortStatus {
    /// Same meaning as the old web UI's status dots (OK / warning / no signal / not present).
    var color: Color {
        switch self {
        case .ok: Color.system(.green)
        case .warning: Color.system(.orange)
        case .moduleFault: Color.system(.red)
        case .noSignal: Color.gray
        case .moduleNotPresent: Color.gray.opacity(0.4)
        }
    }
}

struct StatusDot: View {
    var status: PortStatus
    var size = 8

    var body: some View {
        Circle()
            .foregroundColor(status.color)
            .frame(width: size, height: size)
    }
}
