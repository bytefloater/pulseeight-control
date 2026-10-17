import PulseEightKit
import SwiftUI

extension PortStatus {
    /// Same meaning as the old web UI's status dots (OK / warning / no signal / not present).
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .moduleFault: .red
        case .noSignal: .gray
        case .moduleNotPresent: .gray.opacity(0.4)
        }
    }
}

struct StatusDot: View {
    var status: PortStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
    }
}
