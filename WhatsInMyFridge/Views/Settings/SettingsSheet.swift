import SwiftUI
import SwiftData

/// API key (Keychain), notification hour, default storage, and the lifetime
/// eaten/tossed counters — the only stats in v1.
struct SettingsSheet: View {
    var showKeyExplainer = false

    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9
    @AppStorage("defaultStorage") private var defaultStorageRaw = StorageLocation.fridge.rawValue

    @State private var apiKey: String = KeychainStore.apiKey ?? ""

    @Query(filter: #Predicate<FridgeItem> { $0.statusRaw == "eaten" })
    private var eatenItems: [FridgeItem]
    @Query(filter: #Predicate<FridgeItem> { $0.statusRaw == "tossed" })
    private var tossedItems: [FridgeItem]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if showKeyExplainer {
                        Label("Scanning needs an Anthropic API key. Paste yours below — it stays on this device.",
                              systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.soon)
                    }
                    SecureField("sk-ant-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Anthropic API key")
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

                Section {
                } footer: {
                    Text("You've eaten \(eatenItems.count) item\(eatenItems.count == 1 ? "" : "s") and tossed \(tossedItems.count).")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
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
