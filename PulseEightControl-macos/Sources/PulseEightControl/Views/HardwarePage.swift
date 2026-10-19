import PulseEightCore
import PulseEightKit
import SwiftUI

/// The Hardware page's topics, in the order the Windows app lists them (Maintenance, the restart, is macOS's own).
enum HardwareTopic: String, CaseIterable, Identifiable {
    case system, features, health, diagnostics, frontPanel, maintenance, updates, inputs, outputs

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: "cpu"
        case .features: "checklist"
        case .health: "heart.text.square"
        case .diagnostics: "thermometer.medium"
        case .frontPanel: "light.max"
        case .maintenance: "wrench.and.screwdriver"
        case .updates: "arrow.down.circle"
        case .inputs: "tray.and.arrow.down"
        case .outputs: "tray.and.arrow.up"
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .system: strings.text(.hardwareSystem)
        case .features: strings.text(.hardwareFeatures)
        case .health: strings.text(.hardwareHealth)
        case .diagnostics: strings.text(.hardwareDiagnostics)
        case .frontPanel: strings.text(.hardwareFrontPanel)
        case .maintenance: "Maintenance"
        case .updates: strings.text(.hardwareFirmwareUpdates)
        case .inputs: strings.text(.hardwareInputs)
        case .outputs: strings.text(.hardwareOutputs)
        }
    }

    func description(_ strings: Strings) -> String {
        switch self {
        case .system: strings.text(.hardwareSystemDescription)
        case .features: strings.text(.hardwareFeaturesDescription)
        case .health: strings.text(.hardwareHealthDescription)
        case .diagnostics: strings.text(.hardwareDiagnosticsDescription)
        case .frontPanel: strings.text(.hardwareFrontPanelDescription)
        case .maintenance: "Restart the matrix"
        case .updates: strings.text(.hardwareFirmwareDescription)
        case .inputs: strings.text(.hardwareInputsDescription)
        case .outputs: strings.text(.hardwareOutputsDescription)
        }
    }
}

enum BacklightOption: CaseIterable, Hashable {
    case off, low, high

    var titleKey: StringKey {
        switch self {
        case .off: .hardwareBacklightOff
        case .low: .hardwareBacklightLow
        case .high: .hardwareBacklightHigh
        }
    }

    var level: BacklightLevel {
        switch self {
        case .off: .off
        case .low: .low
        case .high: .high
        }
    }

    init(_ level: BacklightLevel) {
        switch level {
        case .off: self = .off
        case .low: self = .low
        case .high: self = .high
        }
    }
}

/// The Hardware section, laid out like the Windows app's: a list of topics (System, Features, Health, ...), each
/// opening its own page under a "Hardware › Topic" heading, with the heading staying put while the content slides.
struct HardwarePage: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the page being drawn arrived from, for the slide: 1 opening a topic, -1 going back.
    @State private var direction: CGFloat = 1

    private var strings: Strings { model.core.strings }

    var body: some View {
        if let state = model.state {
            let topic = shownTopic(state)
            Group {
                if let topic { page(topic, state) } else { topicList(state) }
            }
            .id(topic?.rawValue ?? "list")
            .transition(.asymmetric(insertion: .slideFade(from: 40 * direction), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            // A topic that has gone (the front panel once the admin password is removed) falls back to the list.
            .onChange(of: model.hardwareTopic != nil && topic == nil) { _, gone in
                if gone { model.hardwareTopic = nil }
            }
        }
    }

    // MARK: Navigation

    private func go(_ topic: HardwareTopic?) {
        direction = topic == nil ? -1 : 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) { model.hardwareTopic = topic }
    }

    private func shownTopic(_ state: MatrixState) -> HardwareTopic? {
        model.hardwareTopic.flatMap { isAvailable($0, state) ? $0 : nil }
    }

    private func isAvailable(_ topic: HardwareTopic, _ state: MatrixState) -> Bool {
        switch topic {
        case .health: healthRows(state).contains { $0.group != "diagnostics" }
        case .diagnostics: healthRows(state).contains { $0.group == "diagnostics" }
        case .frontPanel:
            model.adminConfigured && (state.system?.features.backlightLED != nil || state.system?.features.statusLED != nil)
        case .maintenance: model.adminConfigured
        default: true
        }
    }

    /// "Hardware" at the size of a page title, or "Hardware › Topic" with "Hardware" taking you back. It is the header of
    /// the form's first section, so it lines up with the cards however wide the window is, and is the same height either
    /// way, so nothing below it moves.
    private func header(_ topic: HardwareTopic?) -> some View {
        HStack(spacing: 8) {
            if let topic {
                Button { go(nil) } label: { Text(strings.text(.hardwareTitle)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(strings.text(.commonBack))
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                Text(topic.title(strings))
            } else {
                Text(strings.text(.hardwareTitle))
            }
            Spacer()
        }
        .font(.title2.weight(.semibold))
        .foregroundStyle(.primary)
        .textCase(nil)
        .lineLimit(1)
        .frame(height: 34)
        .onExitCommand { if topic != nil { go(nil) } }
    }

    // MARK: The list of topics

    private func topicList(_ state: MatrixState) -> some View {
        Form {
            Section {
                ForEach(HardwareTopic.allCases.filter { isAvailable($0, state) }) { topic in
                    topicRow(topic, state)
                }
            } header: {
                header(nil)
            }
        }
        .formStyle(.grouped)
    }

    private func topicRow(_ topic: HardwareTopic, _ state: MatrixState) -> some View {
        Button { go(topic) } label: {
            HStack(spacing: 14) {
                Image(systemName: topic.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(topic.title(strings))
                    Text(topic.description(strings)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                trailing(topic, state)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A glance at a topic without opening it: the model, whether the matrix is well, how many updates, how many ports.
    @ViewBuilder
    private func trailing(_ topic: HardwareTopic, _ state: MatrixState) -> some View {
        switch topic {
        case .system:
            if let model = state.system?.details.model, !model.isEmpty { note(model) }
        case .health:
            // A tick if the matrix says it is well and nothing it reports is not.
            let judged = healthRows(state).filter { $0.ok != nil }
            if !judged.isEmpty { healthGlyph(ok: judged.allSatisfy { $0.ok == true }) }
        case .updates:
            if !state.updates.isEmpty {
                note(strings.count(state.updates.count, one: .statusBarFirmwareUpdateOne, other: .statusBarFirmwareUpdateOther))
            }
        case .inputs: note(String(state.inputs.count))
        case .outputs: note(String(state.outputs.count))
        default: EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: A topic's page

    @ViewBuilder
    private func page(_ topic: HardwareTopic, _ state: MatrixState) -> some View {
        Form {
            // The heading is the header of the page's first (only) section, exactly as on the list of topics, so the space
            // between it and the first card is the same on every page.
            switch topic {
            case .system: systemSection(state, topic)
            case .features: rowsSection(state.system.map { Presentation.featureRows($0.features, strings) } ?? [], topic)
            case .health: rowsSection(healthRows(state).filter { $0.group != "diagnostics" }, topic, judged: true)
            case .diagnostics: rowsSection(healthRows(state).filter { $0.group == "diagnostics" }, topic, judged: true)
            case .frontPanel:
                if let features = state.system?.features { frontPanelSection(features, topic) }
            case .maintenance: maintenanceSection(topic)
            case .updates: updatesSection(state, topic)
            case .inputs: portsSection(state.inputs, state, topic)
            case .outputs: portsSection(state.outputs, state, topic)
            }
        }
        .formStyle(.grouped)
    }

    private func healthRows(_ state: MatrixState) -> [LabeledValue] {
        state.health.map { Presentation.healthRows($0, strings) } ?? []
    }

    /// Label/value lines, with a tick or warning beside the ones the matrix judges.
    private func rowsSection(_ rows: [LabeledValue], _ topic: HardwareTopic, judged: Bool = false) -> some View {
        Section {
            if rows.isEmpty {
                Text(strings.text(.hardwareNothingYet)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label) {
                        if judged, let ok = row.ok {
                            HStack(spacing: 6) {
                                healthGlyph(ok: ok)
                                Text(row.value).textSelection(.enabled)
                            }
                        } else {
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            header(topic)
        }
    }

    private func healthGlyph(ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    /// The system details, or why there are none: the matrix refused them, or they haven't arrived yet.
    private func systemSection(_ state: MatrixState, _ topic: HardwareTopic) -> some View {
        let rows = state.system.map { Presentation.systemRows($0, strings) } ?? []
        return Group {
            if !rows.isEmpty {
                rowsSection(rows, topic)
            } else {
                Section {
                    if let error = state.systemError {
                        Label(strings.text(.hardwareSystemError), systemImage: "exclamationmark.triangle")
                        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text(strings.text(.hardwareSystemPending)).foregroundStyle(.secondary)
                    }
                } header: {
                    header(topic)
                }
            }
        }
    }

    private func frontPanelSection(_ f: SystemFeatures, _ topic: HardwareTopic) -> some View {
        Section {
            if let level = f.backlight {
                ControlRow(strings.text(.hardwareBacklight)) {
                    Picker(strings.text(.hardwareBacklight), selection: backlightBinding(current: level)) {
                        ForEach(BacklightOption.allCases, id: \.self) { Text(strings.text($0.titleKey)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(model.backlightPending != nil)
                }
            }
            if let on = f.statusLEDOn {
                ControlRow(strings.text(.hardwareStatusLight)) {
                    Toggle(strings.text(.hardwareStatusLight), isOn: statusLEDBinding(current: on))
                        .disabled(model.statusLEDPending != nil)
                }
            }
            if let error = model.frontPanelError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            header(topic)
        }
    }

    /// Admin only. The restart itself is only sent after the confirmation alert (see `AppModel.requestRestart`).
    private func maintenanceSection(_ topic: HardwareTopic) -> some View {
        Section {
            ControlRow("Restart") {
                Button("Restart Matrix…", role: .destructive) { model.requestRestart() }
            }
        } header: {
            header(topic)
        } footer: {
            Text("Restarting interrupts everything routed through the matrix for about a minute.")
        }
    }

    private func updatesSection(_ state: MatrixState, _ topic: HardwareTopic) -> some View {
        Section {
            if state.updates.isEmpty {
                Text(strings.text(.hardwareAllUpToDate)).foregroundStyle(.secondary)
            } else {
                ForEach(state.updates) { update in
                    Button {
                        model.openPort(PortSelection(mode: .output, bay: update.bay))
                    } label: {
                        HStack {
                            Text(update.name)
                            Spacer()
                            Text(update.firmwareVersion.flatMap { $0.isEmpty ? nil : strings.text(.hardwareVersionAvailable, $0) }
                                ?? strings.text(.hardwareUpdateAvailable))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            header(topic)
        }
    }

    private func portsSection(_ ports: [MatrixPort], _ state: MatrixState, _ topic: HardwareTopic) -> some View {
        Section {
            if ports.isEmpty {
                Text(strings.text(.hardwareNoPorts)).foregroundStyle(.secondary)
            } else {
                ForEach(ports) { port in
                    Button {
                        model.openPort(PortSelection(mode: port.mode, bay: port.bay))
                    } label: {
                        let label = Presentation.statusLabel(port.status, strings)
                        let update = port.mode == .output && state.outputDetails[port.bay]?.firmwareVersionAvailable == true
                        HStack(spacing: 10) {
                            StatusDot(status: port.status)
                            Text("\(port.bay + 1)  \(port.name)").lineLimit(1)
                            Spacer()
                            note(update ? strings.text(.hardwarePortUpdateAvailable, label) : label)
                            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            header(topic)
        }
    }

    // MARK: Helpers

    private func backlightBinding(current: BacklightLevel) -> Binding<BacklightOption> {
        Binding(
            get: { BacklightOption(model.backlightPending ?? current) },
            set: { if $0.level != (model.backlightPending ?? current) { model.setBacklight($0.level) } }
        )
    }

    private func statusLEDBinding(current: Bool) -> Binding<Bool> {
        Binding(
            get: { model.statusLEDPending ?? current },
            set: { model.setStatusLED(on: $0) }
        )
    }
}

/// The content of a page arriving: it fades in while gliding a short way (from the right when opening a topic, from the
/// left when going back). Only the content does this; the heading stays put.
private struct SlideFade: ViewModifier {
    var x: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).opacity(opacity)
    }
}

extension AnyTransition {
    fileprivate static func slideFade(from x: CGFloat) -> AnyTransition {
        .modifier(active: SlideFade(x: x, opacity: 0), identity: SlideFade(x: 0, opacity: 1))
    }
}
