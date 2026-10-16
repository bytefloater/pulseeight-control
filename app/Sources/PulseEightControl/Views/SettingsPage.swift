import SwiftCrossUI

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 20) {
                FormSection("Matrix") {
                    field("Host", "192.168.1.150", text: $model.draft.host, width: 240)
                    field("Port", "80", text: $model.draft.port, width: 70)
                    field("Timeout (s)", "10", text: $model.draft.timeout, width: 70)
                    field("Poll interval (s)", "5", text: $model.draft.pollInterval, width: 70)
                    field("Detail poll interval (s)", "20", text: $model.draft.detailPollInterval, width: 70)
                }
                Divider()
                FormSection("Admin") {
                    FormRow("Admin password") {
                        SecureField(model.adminConfigured ? "Saved. Leave blank to keep it" : "Optional", text: $model.draft.adminPassword)
                            .frame(width: 240)
                        if model.adminConfigured {
                            Button("Remove") { model.removeAdminPassword() }
                        }
                    }
                    FormRow("") {
                        Text("Needed to rename ports and change EDID or front panel settings. Stored in the system's secure storage, never in the settings file.")
                            .font(.caption)
                    }
                }
                Divider()
                FormSection("Appearance") {
                    FormRow("Theme") {
                        Picker(of: Appearance.allCases, selection: appearanceBinding)
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                    }
                }
                Divider()
                FormRow("") {
                    Button("Save") { model.saveSettings() }
                    if let message = model.settingsMessage {
                        if message.isError {
                            Text(message.text).foregroundColor(Color.system(.red))
                        } else {
                            Text(message.text)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .topLeading)
        }
    }

    var appearanceBinding: Binding<Appearance?> {
        Binding(
            get: { model.draft.appearance },
            set: { if let value = $0 { model.setAppearance(value) } }
        )
    }

    func field(_ label: String, _ prompt: String, text: Binding<String>, width: Int) -> some View {
        FormRow(label) {
            TextField(prompt, text: text).frame(width: width)
        }
    }
}
