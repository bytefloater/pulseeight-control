#if os(macOS)
    import AppKit
    import SwiftUI

    /// The macOS Settings window. Built with SwiftUI rather than SwiftCrossUI so it gets the real
    /// system sidebar (Liquid Glass, native metrics), the window title from `navigationTitle`, and
    /// grouped form rows that match System Settings exactly. `AppModel` is an Apple `@Observable`,
    /// so SwiftUI observes it directly.
    @MainActor
    enum NativeSettings {
        private static var window: NSWindow?

        static func show(model: AppModel) {
            model.resetDraft()
            if let window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let controller = NSHostingController(rootView: NativeSettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.title = model.settingsPane.title
            window.setContentSize(NSSize(width: 720, height: 520))
            window.center()
            window.setFrameAutosaveName("PulseEightControl.Settings")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // No text field should start out focused and selected.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }

        /// The hosting controller doesn't forward `navigationTitle`, so the title follows the pane here.
        static func setTitle(_ title: String) {
            window?.title = title
        }
    }

    struct NativeSettingsView: View {
        @Bindable var model: AppModel

        var body: some View {
            NavigationSplitView {
                List(selection: paneBinding) {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                .navigationSplitViewColumnWidth(220)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                Form {
                    switch model.settingsPane {
                    case .matrix: matrixPane
                    case .admin: adminPane
                    case .appearance: appearancePane
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(model.settingsPane.title)
            }
            .onChange(of: model.settingsPane) { NativeSettings.setTitle(model.settingsPane.title) }
            .preferredColorScheme(colorScheme)
        }

        // MARK: Panes

        @ViewBuilder
        var matrixPane: some View {
            Section("Connection") {
                TextField("Host", text: $model.draft.host, prompt: Text("192.168.1.150"))
                    .multilineTextAlignment(.trailing)
                TextField("Port", text: $model.draft.port, prompt: Text("80"))
                    .multilineTextAlignment(.trailing)
                TextField("Timeout (seconds)", text: $model.draft.timeout, prompt: Text("10"))
                    .multilineTextAlignment(.trailing)
                TextField("Poll interval (seconds)", text: $model.draft.pollInterval, prompt: Text("5"))
                    .multilineTextAlignment(.trailing)
                TextField("Detail poll interval (seconds)", text: $model.draft.detailPollInterval, prompt: Text("20"))
                    .multilineTextAlignment(.trailing)
                applyRow
            }
        }

        @ViewBuilder
        var adminPane: some View {
            Section {
                SecureField(
                    "Password",
                    text: $model.draft.adminPassword,
                    prompt: Text(model.adminConfigured ? "Saved" : "Optional")
                )
                .multilineTextAlignment(.trailing)
                if model.adminConfigured {
                    Button("Remove Saved Password", role: .destructive) { model.removeAdminPassword() }
                }
                applyRow
            } header: {
                Text("Admin Password")
            } footer: {
                Text("Needed to rename ports and change EDID or front panel settings. It is stored in the system's secure storage, never in the settings file.")
            }
        }

        @ViewBuilder
        var appearancePane: some View {
            Section("Theme") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.description).tag($0) }
                }
            }
            Section("Window") {
                Toggle("Highlight row and column", isOn: highlightBinding)
                Toggle("Show status bar", isOn: statusBarBinding)
            }
        }

        /// Message (if any) and the Apply button, as the last row of a group.
        var applyRow: some View {
            HStack {
                if let message = model.settingsMessage {
                    Text(message.text).foregroundStyle(message.isError ? Color.red : Color.secondary)
                }
                Spacer()
                Button("Apply") { model.saveSettings() }
            }
        }

        // MARK: Bindings

        var paneBinding: Binding<SettingsPane?> {
            Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })
        }

        var appearanceBinding: Binding<Appearance> {
            Binding(get: { model.draft.appearance }, set: { model.setAppearance($0) })
        }

        var highlightBinding: Binding<Bool> {
            Binding(get: { model.settings.highlightGrid }, set: { model.setHighlightGrid($0) })
        }

        var statusBarBinding: Binding<Bool> {
            Binding(get: { model.settings.showStatusBar }, set: { model.setShowStatusBar($0) })
        }

        var colorScheme: ColorScheme? {
            switch model.settings.appearance {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }
#endif
