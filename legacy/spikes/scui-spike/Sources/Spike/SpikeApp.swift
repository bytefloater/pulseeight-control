import DefaultBackend

#if os(macOS)
    import AppKitBackend
#endif
import Foundation
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

// THROWAWAY M0 spike. Each screen exercises one of the risky pieces from the plan:
//   Routing  - NxN grid, onHover row/column highlight, tap, tooltips, cell style (Rectangle vs Button)
//   Hardware - Table with a view column, segmented Picker, switch Toggle, sheet with TextField + Picker
//   Settings - preferredColorScheme override, Color.system palette
//   Menu bar - .commands

enum Page: String, CaseIterable, Identifiable, CustomStringConvertible {
    case routing, hardware, settings

    var id: String { rawValue }
    var description: String { rawValue.capitalized }
}

enum Appearance: String, CaseIterable, CustomStringConvertible {
    case system, light, dark

    var description: String { rawValue.capitalized }
}

@Observable
class SpikeModel {
    var size = 16
    var routes: [Int: Int] = [:]  // output -> input
    var hoverRow: Int?
    var hoverCol: Int?
    var highlightEnabled = true
    var useButtonCells = false
    var clicks = 0
    var hoverEvents = 0
    var refreshes = 0
    var appearance: Appearance = .system
    var backlight: String? = "high"
    var statusLED = true
    var showSheet = false
}

struct PortRow: Identifiable {
    var id: Int
    var name: String
    var status: String
    var signal: String
}

@main
struct SpikeApp: App {
    @State var model = SpikeModel()
    @State var page: Page? = .routing

    var body: some Scene {
        WindowGroup("SwiftCrossUI Spike") {
            NavigationSplitView {
                List(Page.allCases, id: \.self, selection: $page)
                    .padding(8)
            } detail: {
                VStack(alignment: .leading, spacing: 0) {
                    switch page ?? .routing {
                    case .routing: RoutingPage(model: model)
                    case .hardware: HardwarePage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                    Divider()
                    HStack {
                        Circle().foregroundColor(Color.system(.green)).frame(width: 10, height: 10)
                        Text("Connected (192.168.1.150)")
                        Spacer()
                        Text("sheet \(model.showSheet ? "ON" : "off")  clicks \(model.clicks)  hover events \(model.hoverEvents)  refresh \(model.refreshes)")
                    }
                    .padding(8)
                }
            }
            .preferredColorScheme(model.appearance == .system ? nil : (model.appearance == .dark ? .dark : .light))
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Matrix") {
                Button("Refresh") { model.refreshes += 1 }
                Button("Reconnect") { model.refreshes += 1 }
                Divider()
                Toggle("Highlight row and column", isOn: $model.highlightEnabled)
            }
        }
    }
}

// MARK: - Routing

struct RoutingPage: View {
    @Bindable var model: SpikeModel
    @State var sizeChoice: Int? = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid size")
                Picker(of: [4, 8, 16, 32], selection: $sizeChoice)
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                Toggle("Highlight", isOn: $model.highlightEnabled)
                Toggle("Button cells", isOn: $model.useButtonCells)
                Text("Tap me")
                    .padding()
                    .background(Color.green)
                    .onTapGesture { model.clicks += 100 }
            }
            .padding(8)
            .onChange(of: sizeChoice) {
                model.size = sizeChoice ?? 16
            }
            ScrollView([.horizontal, .vertical]) {
                RoutingGrid(model: model)
                    .padding(8)
            }
        }
    }
}

struct RoutingGrid: View {
    @Bindable var model: SpikeModel
    static let cell = 28.0
    static let rowHeader = 130.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column headers. Rotating text isn't possible (no rotationEffect), so: number + tooltip.
            HStack(spacing: 0) {
                Text("").frame(width: Self.rowHeader, height: Self.cell)
                ForEach(0..<model.size, id: \.self) { input in
                    headerLabel("\(input + 1)", highlighted: model.highlightEnabled && model.hoverCol == input)
                        .frame(width: Self.cell, height: Self.cell)
                        .help("Input \(input + 1): Source name \(input + 1)")
                }
            }
            ForEach(0..<model.size, id: \.self) { output in
                HStack(spacing: 0) {
                    headerLabel("Output name \(output + 1)", highlighted: model.highlightEnabled && model.hoverRow == output)
                        .lineLimit(1)
                        .frame(width: Self.rowHeader, height: Self.cell, alignment: .trailing)
                        .padding(.trailing, 6)
                    ForEach(0..<model.size, id: \.self) { input in
                        GridCell(model: model, input: input, output: output)
                    }
                }
            }
        }
    }
}

extension RoutingGrid {
    // No Color.primary / semantic label colors, so only override the colour when highlighted
    // and otherwise inherit the platform's default text colour.
    @ViewBuilder
    func headerLabel(_ text: String, highlighted: Bool) -> some View {
        if highlighted {
            Text(text).foregroundColor(Color.system(.blue))
        } else {
            Text(text)
        }
    }
}

struct GridCell: View {
    @Bindable var model: SpikeModel
    var input: Int
    var output: Int

    var body: some View {
        let active = model.routes[output] == input
        let highlighted = model.highlightEnabled && (model.hoverRow == output || model.hoverCol == input)
        Group {
            if model.useButtonCells {
                Button(active ? "●" : "") { select() }
                    .frame(width: RoutingGrid.cell, height: RoutingGrid.cell)
            } else {
                // Text + background rather than Rectangle: onTapGesture did not fire on a bare Rectangle.
                Text("")
                    .frame(width: RoutingGrid.cell - 2, height: RoutingGrid.cell - 2)
                    .background(
                        active ? Color.system(.blue)
                            : (highlighted ? Color.gray.opacity(0.35) : Color.gray.opacity(0.12))
                    )
                    .padding(1)
            }
        }
        .onHover { hovering in
            guard hovering else { return }
            model.hoverEvents += 1
            model.hoverRow = output
            model.hoverCol = input
        }
        .help("Source name \(input + 1) → Output name \(output + 1)")
        // Outermost on purpose: when onTapGesture sat inside onHover/help, clicks never arrived.
        .onTapGesture { select() }
    }

    func select() {
        model.routes[output] = input
        model.clicks += 1
    }
}

// MARK: - Hardware

struct HardwarePage: View {
    @Bindable var model: SpikeModel
    @State var renameText = "Lounge TV"
    @State var edid: Int? = 0

    var rows: [PortRow] {
        (0..<8).map { PortRow(id: $0, name: "Output \($0 + 1)", status: $0 == 3 ? "No signal" : "OK", signal: "3840x2160@60") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Front Panel").font(.headline)
                Button("Open sheet (outside table)") { model.showSheet = true }
            }
            HStack {
                Text("Backlight")
                Picker(of: ["off", "low", "high"], selection: $model.backlight)
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                Toggle("Status LEDs", isOn: $model.statusLED)
                    .toggleStyle(.switch)
            }
            Text("Ports").font(.headline)
            Table(rows) {
                TableColumn("Name", value: \PortRow.name)
                TableColumn("Status") { (row: PortRow) in
                    HStack {
                        Circle()
                            .foregroundColor(row.status == "OK" ? Color.system(.green) : Color.system(.orange))
                            .frame(width: 10, height: 10)
                        Text(row.status)
                    }
                }
                TableColumn("Signal", value: \PortRow.signal)
                TableColumn("") { (row: PortRow) in
                    Button("Edit…") { model.showSheet = true }
                }
            }
            Spacer()
        }
        .padding(12)
        .sheet(isPresented: $model.showSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit port").font(.headline)
                TextField("Name (13 characters max)", text: $renameText)
                Picker(of: [0, 2, 3, 11], selection: $edid)
                    .pickerStyle(.menu)
                HStack {
                    Spacer()
                    Button("Done") { model.showSheet = false }
                }
            }
            .padding(20)
            .frame(minWidth: 320)
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @Bindable var model: SpikeModel
    @State var appearance: Appearance? = .system
    @State var host = "192.168.1.150"
    @State var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            HStack {
                Text("Host")
                TextField("192.168.1.150", text: $host).frame(width: 220)
            }
            HStack {
                Text("Admin password")
                SecureField("Optional", text: $password).frame(width: 220)
            }
            HStack {
                Text("Appearance")
                Picker(of: Appearance.allCases, selection: $appearance)
                    .pickerStyle(.segmented)
                    .frame(width: 260)
            }
            .onChange(of: appearance) {
                model.appearance = appearance ?? .system
            }
            Text("Platform palette (Color.system)").font(.headline)
            HStack {
                swatch(Color.system(.blue))
                swatch(Color.system(.green))
                swatch(Color.system(.orange))
                swatch(Color.system(.red))
                swatch(Color.system(.gray))
            }
            Spacer()
        }
        .padding(12)
    }

    func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6).foregroundColor(color).frame(width: 44, height: 44)
    }
}
