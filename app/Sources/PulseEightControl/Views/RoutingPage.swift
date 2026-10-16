import PulseEightKit
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

/// Tells grid tiles when the pointer enters or leaves a row or column. Each tile keeps its own
/// highlighted flag in `@State` and registers a sink here, so a pointer move updates only the
/// tiles in the affected row and column and nothing else. Observation can't be used: Swift
/// merges nested observation tracking, so an `@Observable` read in a tile would also make every
/// ancestor (the whole page) re-run its body, rebuilding all ~270 tiles, on each pointer move.
@Observable
final class HoverRelay {
    struct Position: Equatable {
        var input: Int?
        var output: Int?
    }

    enum Tile: Hashable {
        case cell(input: Int, output: Int)
        case columnHeader(input: Int)
        case rowHeader(output: Int)
    }

    @ObservationIgnored var current: Position?
    @ObservationIgnored private var sinks: [Tile: (Bool) -> Void] = [:]

    func register(_ tile: Tile, sink: @escaping (Bool) -> Void) {
        sinks[tile] = sink
    }

    func set(_ position: Position?) {
        let previous = current
        current = position
        for (tile, sink) in sinks {
            let was = Self.isHighlighted(tile, previous)
            let now = Self.isHighlighted(tile, position)
            if was != now { sink(now) }
        }
    }

    static func isHighlighted(_ tile: Tile, _ position: Position?) -> Bool {
        guard let position else { return false }
        switch tile {
        case .cell(let input, let output): return position.input == input || position.output == output
        case .columnHeader(let input): return position.input == input
        case .rowHeader(let output): return position.output == output
        }
    }
}

enum GridStyle {
    /// Tiles are `pitch - gap` square and separated by `gap` (stack spacing, not per-tile padding:
    /// every wrapper is another AppKit-backed node, and the page is built on each tab switch).
    static let pitch = 28
    static let gap = 4
    static let rowHeaderWidth = 156
    static let idleFill = Color.gray.opacity(0.12)
    /// Row and column under the pointer. Status colours (blue, orange, dots) are left alone.
    static let highlightFill = Color.gray.opacity(0.34)
    static let columnHeaderMinHeight = 96

    /// Tall enough for the longest input name once rotated (names are at most 13 characters),
    /// plus the status dot.
    static func columnHeaderHeight(for inputs: [MatrixPort]) -> Int {
        let longest = inputs.map { $0.name.count }.max() ?? 0
        return max(columnHeaderMinHeight, 50 + Int(Double(longest) * 7.6))
    }
}

/// The crosspoint grid: inputs across, outputs down, one cell per pair. The blue cell in each row
/// is the input currently routed to that output. Headers are part of the grid.
struct RoutingPage: View {
    @Bindable var model: AppModel
    @State var relay = HoverRelay()

    var body: some View {
        let inputs = model.inputs
        let outputs = model.outputs
        let headerHeight = GridStyle.columnHeaderHeight(for: inputs)
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

    func grid(inputs: [MatrixPort], outputs: [MatrixPort], headerHeight: Int) -> some View {
        let highlight = model.settings.highlightGrid
        return VStack(alignment: .leading, spacing: GridStyle.gap) {
            HStack(spacing: GridStyle.gap) {
                Text("").frame(width: GridStyle.rowHeaderWidth - GridStyle.gap, height: headerHeight - GridStyle.gap)
                ForEach(inputs) { input in
                    ColumnHeaderTile(
                        relay: relay,
                        port: input,
                        height: headerHeight,
                        onHover: { setHover($0, input: input.bay, output: nil, enabled: highlight) },
                        onTap: { model.openPort(PortSelection(mode: .input, bay: input.bay)) }
                    )
                }
            }
            ForEach(outputs) { output in
                HStack(spacing: GridStyle.gap) {
                    RowHeaderTile(
                        relay: relay,
                        port: output,
                        onHover: { setHover($0, input: nil, output: output.bay, enabled: highlight) },
                        onTap: { model.openPort(PortSelection(mode: .output, bay: output.bay)) }
                    )
                    ForEach(inputs) { input in
                        GridCell(
                            relay: relay,
                            input: input.bay,
                            output: output.bay,
                            active: output.receiveFrom == input.bay,
                            pending: model.pendingRoutes.contains(RouteKey(input: input.bay, output: output.bay)),
                            onHover: { setHover($0, input: input.bay, output: output.bay, enabled: highlight) },
                            onTap: { model.route(input: input.bay, output: output.bay) }
                        )
                    }
                }
            }
        }
    }

    func setHover(_ hovering: Bool, input: Int?, output: Int?, enabled: Bool) {
        guard enabled else { return }
        let position = HoverRelay.Position(input: input, output: output)
        if hovering {
            relay.set(position)
        } else if relay.current == position {
            // Only clear if we're still on this item; the next one's enter may have arrived first.
            relay.set(nil)
        }
    }
}

/// Input name running up the column, with the status dot at the bottom, inside the tile.
struct ColumnHeaderTile: View {
    var relay: HoverRelay
    var port: MatrixPort
    var height: Int
    var onHover: (Bool) -> Void
    var onTap: () -> Void

    @State var highlighted = false

    var body: some View {
        let _ = relay.register(.columnHeader(input: port.bay)) { [binding = $highlighted] in binding.wrappedValue = $0 }
        VStack(spacing: 8) {
            RotatedLabel(text: port.name)
                .frame(height: height - 44, alignment: .bottom)
            StatusDot(status: port.status)
        }
        .frame(width: GridStyle.pitch - GridStyle.gap, height: height - GridStyle.gap)
        .background(highlighted ? GridStyle.highlightFill : GridStyle.idleFill)
        .cornerRadius(4)
        .onHover(perform: onHover)
        .help("\(port.name): \(port.status.label). Click for details")
        .onTapGesture(perform: onTap)
    }
}

struct RowHeaderTile: View {
    var relay: HoverRelay
    var port: MatrixPort
    var onHover: (Bool) -> Void
    var onTap: () -> Void

    @State var highlighted = false

    var body: some View {
        let _ = relay.register(.rowHeader(output: port.bay)) { [binding = $highlighted] in binding.wrappedValue = $0 }
        HStack(spacing: 8) {
            Text(port.name)
            StatusDot(status: port.status)
        }
        .padding(.horizontal, 8)
        .frame(width: GridStyle.rowHeaderWidth - GridStyle.gap, height: GridStyle.pitch - GridStyle.gap, alignment: .trailing)
        .background(highlighted ? GridStyle.highlightFill : GridStyle.idleFill)
        .cornerRadius(4)
        .onHover(perform: onHover)
        .help("\(port.name): \(port.status.label). Click for details")
        .onTapGesture(perform: onTap)
    }
}

struct GridCell: View {
    var relay: HoverRelay
    var input: Int
    var output: Int
    var active: Bool
    var pending: Bool
    var onHover: (Bool) -> Void
    var onTap: () -> Void

    @State var highlighted = false

    var body: some View {
        let _ = relay.register(.cell(input: input, output: output)) { [binding = $highlighted] in binding.wrappedValue = $0 }
        // No per-cell tooltip: it is one more view per cell, and the highlighted row and column
        // headers already name the input and output.
        // Text + background rather than Button (clips its label at this size) or Rectangle
        // (taps didn't fire in the spike). The marker is the Text's own content so there is no
        // overlay view to swallow clicks. onTapGesture has to be outermost or it never fires.
        Text(active || pending ? "●" : "")
            .foregroundColor(Color.white)
            .frame(width: GridStyle.pitch - GridStyle.gap, height: GridStyle.pitch - GridStyle.gap)
            .background(fill)
            .cornerRadius(4)
            .onHover(perform: onHover)
            .onTapGesture(perform: onTap)
    }

    var fill: Color {
        if pending { return Color.system(.orange) }
        if active { return Color.system(.blue) }
        return highlighted ? GridStyle.highlightFill : GridStyle.idleFill
    }
}
