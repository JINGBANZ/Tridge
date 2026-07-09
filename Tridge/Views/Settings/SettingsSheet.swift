import SwiftUI
import UIKit

/// Notification hour and the copy-diagnostics feedback loop.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9

    @State private var copiedDiagnostics = false
    @State private var collectingDiagnostics = false

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

                Section {
                    Button(action: copyDiagnostics) {
                        Label(diagnosticsLabel, systemImage: diagnosticsIcon)
                    }
                    .disabled(collectingDiagnostics)
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

    private var diagnosticsLabel: String {
        if collectingDiagnostics { return "Collecting…" }
        return copiedDiagnostics ? "Copied to clipboard" : "Copy diagnostics"
    }

    private var diagnosticsIcon: String {
        if collectingDiagnostics { return "hourglass" }
        return copiedDiagnostics ? "checkmark" : "doc.on.doc"
    }

    /// Reading the log store walks and decodes the whole session archive —
    /// seconds of work that freezes (and watchdog-kills) the app if done on the
    /// main thread. Collect on a detached task, then update the UI on the main
    /// actor. `Task {}` alone would inherit this view's main-actor isolation and
    /// still block, so the work must be explicitly detached.
    private func copyDiagnostics() {
        guard !collectingDiagnostics else { return }
        collectingDiagnostics = true
        copiedDiagnostics = false
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                AppLog.recentDiagnostics()
            }.value
            UIPasteboard.general.string = report
            collectingDiagnostics = false
            copiedDiagnostics = true
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
