import PulseEightCore
import PulseEightKit
import SwiftUI

enum GridStyle {
    /// Tiles are `pitch - gap` square and separated by `gap`.
    static let pitch: CGFloat = 28
    static let gap: CGFloat = 4
    static let tile = pitch - gap
    static let rowHeaderWidth: CGFloat = 152
    static let columnHeaderMinHeight: CGFloat = 96
    static let idleFill = Color.primary.opacity(0.07)
    /// Row and column under the pointer. Status colours (blue, orange, dots) are left alone.
    static let highlightFill = Color.primary.opacity(0.2)

    /// Tall enough for the longest input name once rotated (names are at most 13 characters),
    /// plus the status dot.
    static func columnHeaderHeight(for inputs: [MatrixPort]) -> CGFloat {
        let longest = inputs.map { $0.name.count }.max() ?? 0
        return max(columnHeaderMinHeight, 50 + CGFloat(longest) * 7.6)
    }
}

/// What the pointer is over: a crosspoint, or just a header (one of the two is nil).
private struct HoverPosition: Equatable {
    var input: Int?
    var output: Int?
}

/// The crosspoint grid: inputs across, outputs down, one cell per pair. The blue cell in each row
/// is the input currently routed to that output. Headers are part of the grid.
struct RoutingPage: View {
    @Bindable var model: AppModel
    private var strings: Strings { model.strings }
    @State private var hover: HoverPosition?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment

    var body: some View {
        let inputs = model.inputs
        let outputs = model.outputs
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if inputs.isEmpty || outputs.isEmpty {
                        Text(strings.text(.hardwareNoPorts)).foregroundStyle(.secondary)
                    } else {
                        grid(inputs: inputs, outputs: outputs)
                    }
                }
                .padding(24)
                // Keep the grid in the top-left corner; a scroll view otherwise centres short content.
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .alert(strings.text(.routingErrorTitle), isPresented: routeErrorBinding, presenting: model.routeError) { _ in
            Button(strings.text(.commonOK)) {}
        } message: { message in
            Text(message)
        }
    }

    private var routeErrorBinding: Binding<Bool> {
        Binding(get: { model.routeError != nil }, set: { if !$0 { model.routeError = nil } })
    }

    private func grid(inputs: [MatrixPort], outputs: [MatrixPort]) -> some View {
        let headerHeight = GridStyle.columnHeaderHeight(for: inputs)
        let highlight = model.settings.highlightGrid
        return VStack(alignment: .leading, spacing: GridStyle.gap) {
            HStack(spacing: GridStyle.gap) {
                Color.clear.frame(width: GridStyle.rowHeaderWidth - GridStyle.gap, height: headerHeight - GridStyle.gap)
                ForEach(inputs) { input in
                    columnHeader(input, height: headerHeight, highlighted: highlight && hover?.input == input.bay)
                }
            }
            ForEach(outputs) { output in
                HStack(spacing: GridStyle.gap) {
                    rowHeader(output, highlighted: highlight && hover?.output == output.bay)
                    ForEach(inputs) { input in
                        cell(input: input, output: output, highlighted: highlight && isHighlighted(input: input.bay, output: output.bay))
                    }
                }
            }
        }
    }

    private func isHighlighted(input: Int, output: Int) -> Bool {
        guard let hover else { return false }
        return hover.input == input || hover.output == output
    }

    private func setHover(_ hovering: Bool, input: Int?, output: Int?) {
        let position = HoverPosition(input: input, output: output)
        if hovering {
            hover = position
        } else if hover == position {
            // Only clear if we're still on this item; the next one's enter may have arrived first.
            hover = nil
        }
    }

    // MARK: Tiles

    private func columnHeader(_ port: MatrixPort, height: CGFloat, highlighted: Bool) -> some View {
        Button {
            model.openPort(PortSelection(mode: .input, bay: port.bay))
        } label: {
            VStack(spacing: 8) {
                // Reads bottom-to-top, starting just above the status dot.
                Text(port.name)
                    .lineLimit(1)
                    .frame(width: height - 44, alignment: .leading)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16, height: height - 44)
                StatusDot(status: port.status)
            }
            .frame(width: GridStyle.tile, height: height - GridStyle.gap)
            .background(highlighted ? GridStyle.highlightFill : GridStyle.idleFill, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHover($0, input: port.bay, output: nil) }
        .help(strings.text(.routingPortTooltip, port.name, port.bay + 1, Presentation.statusLabel(port.status, strings)))
    }

    private func rowHeader(_ port: MatrixPort, highlighted: Bool) -> some View {
        Button {
            model.openPort(PortSelection(mode: .output, bay: port.bay))
        } label: {
            HStack(spacing: 8) {
                Text(port.name).lineLimit(1)
                StatusDot(status: port.status)
            }
            .padding(.horizontal, 8)
            .frame(width: GridStyle.rowHeaderWidth - GridStyle.gap, height: GridStyle.tile, alignment: .trailing)
            .background(highlighted ? GridStyle.highlightFill : GridStyle.idleFill, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHover($0, input: nil, output: port.bay) }
        .help(strings.text(.routingPortTooltip, port.name, port.bay + 1, Presentation.statusLabel(port.status, strings)))
    }

    private func cell(input: MatrixPort, output: MatrixPort, highlighted: Bool) -> some View {
        let active = output.receiveFrom == input.bay
        let pending = model.pendingRoutes.contains(RouteKey(input: input.bay, output: output.bay))
        return Button {
            model.route(input: input.bay, output: output.bay)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.accentColor : highlighted ? GridStyle.highlightFill : GridStyle.idleFill)
                if pending {
                    // A change is on its way to the matrix and not yet confirmed.
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.85)
                        // Readable on the accent fill when re-sending the already active route.
                        .environment(\.colorScheme, active ? (accentIsLight ? .light : .dark) : colorScheme)
                } else if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(glyphColor)
                }
            }
            .frame(width: GridStyle.tile, height: GridStyle.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHover($0, input: input.bay, output: output.bay) }
        .help(strings.text(.routingRoute, input.name, output.name))
    }

    // MARK: Glyph contrast

    /// Like system controls, glyphs on the accent fill switch to a dark variant when the accent
    /// colour is light (yellow, say), where white would be hard to read.
    private var accentIsLight: Bool {
        let accent = Color.accentColor.resolve(in: environment)
        let luminance = 0.2126 * accent.linearRed + 0.7152 * accent.linearGreen + 0.0722 * accent.linearBlue
        return luminance > 0.5
    }

    private var glyphColor: Color {
        accentIsLight ? Color.black.opacity(0.8) : Color.white
    }
}
