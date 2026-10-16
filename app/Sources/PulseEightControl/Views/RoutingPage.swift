import PulseEightKit
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

/// Carries "the pointer is over this cell" from the grid's cells to `HighlightBands` without going
/// through observation. Observation can't be used here: Swift merges nested observation tracking,
/// so any observable the bands read would also make every ancestor (the whole page) re-run its
/// body on each pointer move. The bands keep the position in their own `@State`, which only
/// updates their own node.
@Observable
final class HoverRelay {
    struct Position: Equatable {
        var input: Int?
        var output: Int?
    }

    @ObservationIgnored var current: Position?
    @ObservationIgnored var sink: ((Position?) -> Void)?

    func set(_ position: Position?) {
        current = position
        sink?(position)
    }
}

/// The crosspoint grid: inputs across, outputs down, one cell per pair. The blue cell in each row
/// is the input currently routed to that output. Headers are part of the grid.
struct RoutingPage: View {
    @Bindable var model: AppModel
    @State var relay = HoverRelay()

    static let pitch = 28
    static let rowHeaderWidth = 156
    static let columnHeaderMinHeight = 96

    /// Tall enough for the longest input name once rotated (names are at most 13 characters),
    /// plus the status dot.
    static func columnHeaderHeight(for inputs: [MatrixPort]) -> Int {
        let longest = inputs.map { $0.name.count }.max() ?? 0
        return max(columnHeaderMinHeight, 50 + Int(Double(longest) * 7.6))
    }

    var body: some View {
        let inputs = model.inputs
        let outputs = model.outputs
        let headerHeight = Self.columnHeaderHeight(for: inputs)
        PageScroll(alignment: .topLeading, scrollsHorizontally: true) {
            VStack(alignment: .leading, spacing: 16) {
                if inputs.isEmpty || outputs.isEmpty {
                    Text("The matrix reported no ports.")
                } else {
                    grid(inputs: inputs, outputs: outputs, headerHeight: headerHeight)
                }
            }
            .padding(24)
        }
        .alert($model.routeError) {
            Button("OK") {}
        }
    }

    // MARK: Grid

    func grid(inputs: [MatrixPort], outputs: [MatrixPort], headerHeight: Int) -> some View {
        ZStack(alignment: .topLeading) {
            if model.settings.highlightGrid {
                HighlightBands(relay: relay, columns: inputs.count, rows: outputs.count, headerHeight: headerHeight)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("").frame(width: Self.rowHeaderWidth, height: headerHeight)
                    ForEach(inputs) { input in
                        columnHeader(input, headerHeight: headerHeight)
                    }
                }
                ForEach(outputs) { output in
                    HStack(spacing: 0) {
                        rowHeader(output)
                        ForEach(inputs) { input in
                            GridCell(
                                active: output.receiveFrom == input.bay,
                                pending: model.pendingRoutes.contains(RouteKey(input: input.bay, output: output.bay)),
                                tooltip: "\(input.name) → \(output.name)",
                                onHover: { hovering in setHover(hovering, input: input.bay, output: output.bay) },
                                onTap: { model.route(input: input.bay, output: output.bay) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// Input names run up the column, with the status dot at the bottom, inside the tile.
    func columnHeader(_ input: MatrixPort, headerHeight: Int) -> some View {
        VStack(spacing: 8) {
            RotatedLabel(text: input.name)
                .frame(height: headerHeight - 44, alignment: .bottom)
            StatusDot(status: input.status)
        }
        .frame(width: Self.pitch - 4, height: headerHeight - 4)
        .background(GridCell.idleFill)
        .cornerRadius(4)
        .padding(2)
        .onHover { hovering in setHover(hovering, input: input.bay, output: nil) }
        .help("\(input.name): \(input.status.label). Click for details")
        .onTapGesture { model.openPort(PortSelection(mode: .input, bay: input.bay)) }
    }

    func rowHeader(_ output: MatrixPort) -> some View {
        HStack(spacing: 8) {
            Text(output.name)
            StatusDot(status: output.status)
        }
        .padding(.horizontal, 8)
        .frame(width: Self.rowHeaderWidth - 4, height: Self.pitch - 4, alignment: .trailing)
        .background(GridCell.idleFill)
        .cornerRadius(4)
        .padding(2)
        .onHover { hovering in setHover(hovering, input: nil, output: output.bay) }
        .help("\(output.name): \(output.status.label). Click for details")
        .onTapGesture { model.openPort(PortSelection(mode: .output, bay: output.bay)) }
    }

    func setHover(_ hovering: Bool, input: Int?, output: Int?) {
        let position = HoverRelay.Position(input: input, output: output)
        if hovering {
            relay.set(position)
        } else if relay.current == position {
            // Only clear if we're still on this item; the next one's enter may have arrived first.
            relay.set(nil)
        }
    }
}

/// Two translucent bands behind the grid, following the pointer.
struct HighlightBands: View {
    var relay: HoverRelay
    @State var position: HoverRelay.Position?
    var columns: Int
    var rows: Int
    var headerHeight: Int

    var body: some View {
        let pitch = RoutingPage.pitch
        let totalWidth = RoutingPage.rowHeaderWidth + columns * pitch
        let totalHeight = headerHeight + rows * pitch
        // Re-pointed on every body run so it always targets the live State storage.
        let _ = { relay.sink = { [binding = $position] in binding.wrappedValue = $0 } }()
        ZStack(alignment: .topLeading) {
            if let output = position?.output {
                Color.gray.opacity(0.22)
                    .cornerRadius(4)
                    .frame(width: totalWidth, height: pitch)
                    .padding(.top, headerHeight + output * pitch)
            }
            if let input = position?.input {
                Color.gray.opacity(0.22)
                    .cornerRadius(4)
                    .frame(width: pitch, height: totalHeight)
                    .padding(.leading, RoutingPage.rowHeaderWidth + input * pitch)
            }
        }
        .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
    }
}


struct GridCell: View {
    var active: Bool
    var pending: Bool
    var tooltip: String
    var onHover: (Bool) -> Void
    var onTap: () -> Void

    static let idleFill = Color.gray.opacity(0.12)

    var body: some View {
        // Text + background rather than Button (clips its label at this size) or Rectangle
        // (taps didn't fire in the spike). The marker is the Text's own content so there is no
        // overlay view to swallow clicks. onTapGesture has to be outermost or it never fires.
        Text(active || pending ? "●" : "")
            .foregroundColor(Color.white)
            .frame(width: RoutingPage.pitch - 4, height: RoutingPage.pitch - 4)
            .background(fill)
            .cornerRadius(4)
            .padding(2)
            .onHover(perform: onHover)
            .help(tooltip)
            .onTapGesture(perform: onTap)
    }

    var fill: Color {
        if pending { return Color.system(.orange) }
        if active { return Color.system(.blue) }
        return Self.idleFill
    }
}
