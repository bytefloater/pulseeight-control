import PulseEightKit
import SwiftCrossUI

/// The crosspoint grid: inputs across, outputs down, one cell per pair. The active cell in each
/// row is the input currently routed to that output.
struct RoutingPage: View {
    @Bindable var model: AppModel
    @State var hoverInput: Int?
    @State var hoverOutput: Int?

    static let cell = 28.0
    static let rowHeader = 150.0

    var body: some View {
        let inputs = model.state?.inputs ?? []
        let outputs = model.state?.outputs ?? []
        PageScroll(axes: [.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                if inputs.isEmpty || outputs.isEmpty {
                    Text("The matrix reported no ports.")
                } else {
                    grid(inputs: inputs, outputs: outputs)
                    legend(inputs: inputs)
                }
            }
            .padding(24)
        }
        .alert($model.routeError) {
            Button("OK") {}
        }
    }

    // MARK: Grid

    func grid(inputs: [MatrixPort], outputs: [MatrixPort]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Rotated headers aren't possible in SwiftCrossUI, so columns are numbered
            // and the names live in the tooltip and the legend below.
            HStack(spacing: 0) {
                Text("").frame(width: Self.rowHeader, height: Self.cell)
                ForEach(inputs) { input in
                    columnHeader(input)
                }
            }
            ForEach(outputs) { output in
                HStack(spacing: 0) {
                    rowHeader(output)
                    ForEach(inputs) { input in
                        GridCell(
                            active: output.receiveFrom == input.bay,
                            pending: model.pendingRoutes.contains(RouteKey(input: input.bay, output: output.bay)),
                            highlighted: hoverInput == input.bay || hoverOutput == output.bay,
                            tooltip: "\(input.name) → \(output.name)",
                            onHover: { hovering in hover(hovering, input: input.bay, output: output.bay) },
                            onTap: { model.route(input: input.bay, output: output.bay) }
                        )
                    }
                }
            }
        }
    }

    func columnHeader(_ input: MatrixPort) -> some View {
        VStack(spacing: 2) {
            StatusDot(status: input.status)
            headerText("\(input.bay + 1)", highlighted: hoverInput == input.bay)
        }
        .frame(width: Self.cell, height: Self.cell)
        .help("\(input.name): \(input.status.label). Click for details")
        .onTapGesture { model.openPort(PortSelection(mode: .input, bay: input.bay)) }
    }

    func rowHeader(_ output: MatrixPort) -> some View {
        HStack(spacing: 6) {
            headerText(output.name, highlighted: hoverOutput == output.bay)
            StatusDot(status: output.status)
        }
        .frame(width: Self.rowHeader, height: Self.cell, alignment: .trailing)
        .padding(.trailing, 6)
        .help("\(output.name): \(output.status.label). Click for details")
        .onTapGesture { model.openPort(PortSelection(mode: .output, bay: output.bay)) }
    }

    // No semantic label colours, so only override the colour when highlighted and otherwise
    // inherit the platform's default text colour.
    @ViewBuilder
    func headerText(_ text: String, highlighted: Bool) -> some View {
        if highlighted {
            Text(text).foregroundColor(Color.system(.blue))
        } else {
            Text(text)
        }
    }

    func hover(_ hovering: Bool, input: Int, output: Int) {
        if hovering {
            hoverInput = input
            hoverOutput = output
        } else if hoverInput == input && hoverOutput == output {
            // Only clear if we're still on this cell; the next cell's enter may have arrived first.
            hoverInput = nil
            hoverOutput = nil
        }
    }

    // MARK: Legend

    func legend(inputs: [MatrixPort]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inputs").font(.headline)
            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    StatusDot(status: input.status)
                    Text("\(input.bay + 1)  \(input.name)")
                }
                .help("\(input.status.label). Click for details")
                .onTapGesture { model.openPort(PortSelection(mode: .input, bay: input.bay)) }
            }
        }
    }
}

struct GridCell: View {
    var active: Bool
    var pending: Bool
    var highlighted: Bool
    var tooltip: String
    var onHover: (Bool) -> Void
    var onTap: () -> Void

    static let size = RoutingPage.cell

    var body: some View {
        // Text + background rather than Button (clips its label at this size) or Rectangle
        // (taps didn't fire in the spike). onTapGesture has to be outermost or it never fires.
        Text("")
            .frame(width: Self.size - 4, height: Self.size - 4)
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
        return highlighted ? Color.gray.opacity(0.35) : Color.gray.opacity(0.12)
    }
}
