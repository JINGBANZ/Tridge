import SwiftUI

/// API key (Keychain), notification hour, and default storage.
struct SettingsSheet: View {
    var showKeyExplainer = false

    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9
    @AppStorage("defaultStorage") private var defaultStorageRaw = StorageLocation.fridge.rawValue

    @State private var apiKey: String = KeychainStore.apiKey ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if showKeyExplainer {
                        Label("Scanning needs an OpenAI API key. Paste yours below — it stays on this device.",
                              systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.soon)
                    }
                    SecureField("sk-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("OpenAI API key")
                } footer: {
                    Text("Stored only in your device Keychain, used only to read receipts.")
                }

                Section("Notifications") {
                    Picker("Reminder hour", selection: $notificationHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }
                }

                Section("Defaults") {
                    Picker("New items go to", selection: $defaultStorageRaw) {
                        ForEach(StorageLocation.allCases, id: \.rawValue) { location in
                            Text(location.label).tag(location.rawValue)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear {
            KeychainStore.apiKey = apiKey
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
