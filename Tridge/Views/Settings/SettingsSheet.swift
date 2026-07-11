import SwiftUI
import SwiftData
import UIKit

/// Notification hour and the copy-diagnostics feedback loop.
struct SettingsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9
    @Query private var items: [FridgeItem]

    @State private var copiedDiagnostics = false
    @State private var collectingDiagnostics = false
    @State private var showingClearConfirmation = false

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
                    Button("Clear all items", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(items.isEmpty)
                } header: {
                    Text("Fridge")
                } footer: {
                    Text("Permanently deletes every item, including your item history.")
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
            .confirmationDialog(
                "Clear all fridge items?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear all items", role: .destructive) { clearAllItems() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all \(items.count) item\(items.count == 1 ? "" : "s") and cannot be undone.")
            }
        }
    }

    private func clearAllItems() {
        Haptics.warning()
        for item in items {
            NotificationService.cancel(for: item.id)
            context.delete(item)
        }
        NotificationService.updateBadge(expiredCount: 0)
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
