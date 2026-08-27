import SwiftUI
import UIKit

/// Notification hour, emoji-free mode, and the copy-diagnostics feedback loop.
/// Owner-picked "one card, danger apart" layout (2026-07-12): everyday rows
/// share one section with emoji icon chips, the destructive action sits alone
/// below, and a version line closes the sheet — no headers or footer prose.
struct SettingsSheet: View {
    let session: HouseholdSession
    let coordinator: AccountSessionCoordinator

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReminderReconciler.reminderHourKey)
    private var notificationHour = ReminderReconciler.defaultHour
    /// Hides all item art: the home grid becomes a name list, and the add,
    /// review, and detail sheets drop their icons.
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    @State private var copiedDiagnostics = false
    @State private var collectingDiagnostics = false
    @State private var showingClearConfirmation = false
    @State private var isClearing = false

    private var items: [InventoryItemSnapshot] { session.items }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $notificationHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    } label: {
                        row(icon: "🔔", "Expiry reminder")
                    }
                    .accessibilityIdentifier("settings.notificationHour")

                    Toggle(isOn: $emojiFreeMode) {
                        row(icon: "🔤", "Emoji-free mode")
                    }
                    .tint(AppTheme.brandGreen)
                    .accessibilityIdentifier("settings.emojiFreeMode")

                    Button(action: copyDiagnostics) {
                        row(icon: "📋", diagnosticsLabel)
                    }
                    .disabled(collectingDiagnostics)
                    .accessibilityIdentifier("settings.copyDiagnostics")
                }

                Section {
                    Button("Clear all items…", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(items.isEmpty || isClearing)
                    .accessibilityIdentifier("settings.clearAll")
                } footer: {
                    Text(versionLine)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // The hour is a local preference, so a change reschedules this
            // installation's pending requests at the new time immediately.
            .onChange(of: notificationHour) { session.refreshReminders() }
            .confirmationDialog(
                "Clear all fridge items?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear all items", role: .destructive) { clearAllItems() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearWarning)
            }
        }
    }

    /// Clear All is an inventory action, not a privacy erasure: the causal
    /// epoch and every past operation stay in this Household's history and
    /// export. The warning has to be honest about the offline case, which is
    /// the one that surprises people.
    private var clearWarning: String {
        let name = coordinator.activeHousehold?.name ?? "this fridge"
        return """
        This clears the current inventory in \(name) for everyone. \
        Items added on an offline device before it receives this clear will \
        also disappear when that device syncs.
        """
    }

    private func clearAllItems() {
        Haptics.warning()
        isClearing = true
        Task {
            await session.clearAll()
            isClearing = false
        }
    }

    /// One settings row: emoji on a soft green chip, then the label in ink —
    /// Buttons would otherwise tint the text like a link.
    private func row(icon emoji: String, _ label: String) -> some View {
        HStack(spacing: AppTheme.settingsRowIconGap) {
            Text(emoji)
                .font(AppTheme.settingsIconFont)
                .frame(width: AppTheme.settingsIconChipSize,
                       height: AppTheme.settingsIconChipSize)
                .background(
                    AppTheme.brandGreen.opacity(AppTheme.chipSoftOpacity),
                    in: RoundedRectangle(cornerRadius: AppTheme.settingsIconChipRadius))
            Text(label)
                .foregroundStyle(AppTheme.ink)
        }
    }

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Tridge \(version) (\(build))"
    }

    private var diagnosticsLabel: String {
        if collectingDiagnostics { return "Collecting…" }
        return copiedDiagnostics ? "Copied to clipboard" : "Copy diagnostics"
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
