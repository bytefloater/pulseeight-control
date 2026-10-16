import SwiftCrossUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case matrix, admin, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: "Matrix"
        case .admin: "Admin"
        case .appearance: "Appearance"
        }
    }

    /// SF Symbol name (macOS only).
    var symbol: String {
        switch self {
        case .matrix: "network"
        case .admin: "lock"
        case .appearance: "paintbrush"
        }
    }
}

#if !os(macOS)
/// The Settings window: an icon sidebar and grouped sections, in the style of System Settings.
struct SettingsWindow: View {
    @Bindable var model: AppModel

    static let width = 720
    static let height = 520
    static let sidebarWidth = 210

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: Double(Self.width), height: Double(Self.height))
        .onAppear { model.resetDraft() }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Clears the window controls, which sit over the sidebar.
            Text("").frame(height: 44)
            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, selected: model.settingsPane == pane)
                    .onTapGesture { model.settingsPane = pane }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: Double(Self.sidebarWidth), height: Double(Self.height), alignment: .topLeading)
        .background(Color.gray.opacity(0.08))
    }

    // MARK: Detail

    var detail: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.settingsPane.title).font(.title3).fontWeight(.semibold)
            switch model.settingsPane {
            case .matrix: matrixPane
            case .admin: adminPane
            case .appearance: appearancePane
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: Double(Self.width - Self.sidebarWidth - 1), height: Double(Self.height), alignment: .topLeading)
    }

    var matrixPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").font(.headline)
            SettingsGroup {
                field("Host", "192.168.1.150", $model.draft.host, width: 220)
                Divider()
                field("Port", "80", $model.draft.port, width: 80)
                Divider()
                field("Timeout (seconds)", "10", $model.draft.timeout, width: 80)
                Divider()
                field("Poll interval (seconds)", "5", $model.draft.pollInterval, width: 80)
                Divider()
                field("Detail poll interval (seconds)", "20", $model.draft.detailPollInterval, width: 80)
                Divider()
                applyRow
            }
        }
    }

    var adminPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Admin Password").font(.headline)
            SettingsGroup {
                SettingsRow("Password") {
                    SecureField(model.adminConfigured ? "Saved. Leave blank to keep it" : "Optional", text: $model.draft.adminPassword)
                        .frame(width: 220)
                    if model.adminConfigured {
                        Button("Remove") { model.removeAdminPassword() }.fixedSize()
                    }
                }
                Divider()
                applyRow
            }
            Text("Needed to rename ports and change EDID or front panel settings. It is stored in the system's secure storage, never in the settings file.")
                .font(.caption)
                .foregroundColor(Color.gray)
        }
    }

    var appearancePane: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Theme").font(.headline)
                SettingsGroup {
                    SettingsRow("Appearance") {
                        Picker(of: Appearance.allCases, selection: appearanceBinding)
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Window").font(.headline)
                SettingsGroup {
                    SettingsRow("Highlight row and column") {
                        Toggle("", isOn: highlightBinding).toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow("Show status bar") {
                        Toggle("", isOn: statusBarBinding).toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    func field(_ label: String, _ prompt: String, _ text: Binding<String>, width: Int) -> some View {
        SettingsRow(label) {
            TextField(prompt, text: text).frame(width: width)
        }
    }

    /// Message on the left, Apply on the right, as the last row of a group.
    var applyRow: some View {
        HStack {
            if let message = model.settingsMessage {
                if message.isError {
                    Text(message.text).foregroundColor(Color.system(.red))
                } else {
                    Text(message.text).foregroundColor(Color.gray)
                }
            }
            Spacer()
            Button("Apply") { model.saveSettings() }.fixedSize()
        }
        .padding(.vertical, 10)
    }

    var appearanceBinding: Binding<Appearance?> {
        Binding(
            get: { model.draft.appearance },
            set: { if let value = $0 { model.setAppearance(value) } }
        )
    }

    var highlightBinding: Binding<Bool> {
        Binding(get: { model.settings.highlightGrid }, set: { model.setHighlightGrid($0) })
    }

    var statusBarBinding: Binding<Bool> {
        Binding(get: { model.settings.showStatusBar }, set: { model.setShowStatusBar($0) })
    }
}

struct SidebarRow: View {
    var pane: SettingsPane
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SettingsSymbol(name: pane.symbol, selected: selected)
                .frame(width: 26, height: 22)
            if selected {
                Text(pane.title).foregroundColor(Color.white)
            } else {
                Text(pane.title)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.systemAccent : Color.clear)
        .cornerRadius(10)
    }
}

/// A rounded container for rows, like a grouped list section.
struct SettingsGroup<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.14))
        .cornerRadius(12)
    }
}

/// Label on the left, control on the right.
struct SettingsRow<Content: View>: View {
    var label: String
    var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            content
        }
        .padding(.vertical, 10)
    }
}
#endif
