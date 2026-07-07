import SwiftUI
import UIKit

/// Notification hour, default storage, and the copy-diagnostics feedback loop.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9
    @AppStorage("defaultStorage") private var defaultStorageRaw = StorageLocation.fridge.rawValue

    @State private var copiedDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
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
                    Button {
                        UIPasteboard.general.string = AppLog.recentDiagnostics()
                        copiedDiagnostics = true
                    } label: {
                        Label(copiedDiagnostics ? "Copied to clipboard" : "Copy diagnostics",
                              systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("This session's app logs (scans, parsing, errors — never your API key). Reproduce the problem first, then copy and paste into a bug report.")
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
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
