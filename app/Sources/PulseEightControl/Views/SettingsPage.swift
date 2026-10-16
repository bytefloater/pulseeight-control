import SwiftCrossUI

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2)

                Text("Matrix").font(.headline)
                field("Host", "192.168.1.150", text: $model.draft.host, width: 240)
                field("Port", "80", text: $model.draft.port, width: 80)
                field("Timeout (s)", "10", text: $model.draft.timeout, width: 80)
                field("Poll interval (s)", "5", text: $model.draft.pollInterval, width: 80)
                field("Detail poll interval (s)", "20", text: $model.draft.detailPollInterval, width: 80)

                Text("Admin").font(.headline)
                Text("Needed to rename ports and change EDID or front panel settings. It is stored in the system's secure storage, not in the settings file.")
                    .font(.caption)
                HStack {
                    Text("Admin password").frame(width: 170, alignment: .leading)
                    SecureField(model.adminConfigured ? "Saved. Leave blank to keep it" : "Optional", text: $model.draft.adminPassword)
                        .frame(width: 240)
                    if model.adminConfigured {
                        Button("Remove") { model.removeAdminPassword() }
                    }
                }

                Text("Appearance").font(.headline)
                Picker(of: Appearance.allCases, selection: appearanceBinding)
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                Button("Save") { model.saveSettings() }
                if let message = model.settingsMessage {
                    if message.isError {
                        Text(message.text).foregroundColor(Color.system(.red))
                    } else {
                        Text(message.text)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    var appearanceBinding: Binding<Appearance?> {
        Binding(
            get: { model.draft.appearance },
            set: { if let value = $0 { model.setAppearance(value) } }
        )
    }

    func field(_ label: String, _ prompt: String, text: Binding<String>, width: Int) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            TextField(prompt, text: text).frame(width: width)
        }
    }
}
