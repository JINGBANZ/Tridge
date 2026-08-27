import SwiftUI

/// What the app shows before Inventory is usable, and Home once it is.
///
/// Every failure is a state with a way forward, never a crash: a store that
/// will not open, an account that cannot be checked yet, or an archive that
/// could not be migrated each leave the user somewhere they can retry. A cold
/// launch never shows a cached account's inventory before the current identity
/// is validated.
struct RootView: View {
    let coordinator: AccountSessionCoordinator

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .task {
                coordinator.observeAccountChanges()
                await coordinator.start()
            }
            // Foreground refresh reports local truth: whatever CloudKit already
            // imported is consumed now. There is no force-sync button, because
            // the container owns its own import and export schedule.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { coordinator.refreshOnForeground() }
            }
            // Shown until Continue is tapped: terminating first brings it back,
            // because acknowledgement is its own installation-wide marker.
            .sheet(isPresented: migrationNoticeBinding) {
                MigrationNoticeSheet { coordinator.acknowledgeMigrationNotice() }
            }
            .alert("Couldn't move your old fridge", isPresented: migrationFailureBinding) {
                Button("Try Again") { coordinator.retryLegacyMigration() }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("""
                Your old inventory is still on this device and nothing was lost. \
                Tridge will try again — the rest of the app works meanwhile.
                """)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.launchState {
        case .preparing:
            LaunchStatusView(message: "Getting your fridge ready…", showsProgress: true)
        case .finishingCloudSetup:
            LaunchStatusView(message: "Finishing iCloud setup…", showsProgress: true)
                .accessibilityIdentifier("launch.finishingCloudSetup")
        case .iCloudAccountRequired(let availability):
            AccountRequiredView(availability: availability) {
                Task { await coordinator.start() }
            }
        case .persistenceUnavailable(let diagnosticID):
            LaunchStatusView(
                message: "Tridge couldn't open your fridge on this device.",
                detail: "Diagnostic \(diagnosticID)",
                retry: { Task { await coordinator.start() } })
        case .ready:
            if let inventory = coordinator.inventory {
                HomeView(session: inventory, coordinator: coordinator)
            } else {
                // Ready without a session is the one-runloop gap while the
                // Active Household is being opened.
                LaunchStatusView(message: "Getting your fridge ready…", showsProgress: true)
            }
        }
    }

    private var migrationNoticeBinding: Binding<Bool> {
        Binding(get: { coordinator.showsMigrationNotice },
                set: { if !$0 { coordinator.acknowledgeMigrationNotice() } })
    }

    private var migrationFailureBinding: Binding<Bool> {
        Binding(get: { coordinator.legacyMigrationFailure != nil }, set: { _ in })
    }
}

/// One centered message on the chilled background, with an optional spinner and
/// Retry. Every launch state that is not Home renders through this, so they all
/// read the same and all announce the same way.
struct LaunchStatusView: View {
    let message: String
    var detail: String?
    var showsProgress = false
    var retry: (() -> Void)?

    var body: some View {
        ZStack {
            AppTheme.ChillBackground()
            VStack(spacing: AppTheme.ghostSpacing) {
                if showsProgress {
                    ProgressView()
                        .tint(AppTheme.brandGreen)
                }
                Text(message)
                    .font(AppTheme.ghostTextFont)
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(AppTheme.countFont)
                        .foregroundStyle(AppTheme.mutedInk)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.brandGreen)
                        .accessibilityIdentifier("launch.retryButton")
                }
            }
            .padding(AppTheme.screenMargin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launch.status")
    }
}

/// The blocking iCloud state. Nothing local is shown behind it: a cached
/// account's inventory must never be visible to whoever is signed in now.
struct AccountRequiredView: View {
    let availability: AccountAvailability
    let retry: () -> Void

    var body: some View {
        LaunchStatusView(message: message,
                         detail: detail,
                         showsProgress: false,
                         retry: availability.isTransient ? retry : nil)
            .accessibilityIdentifier("launch.iCloudRequired")
    }

    private var message: String {
        switch availability {
        case .noAccount: "Sign in to iCloud to use Tridge"
        case .restricted: "iCloud is restricted on this device"
        case .couldNotDetermine, .temporarilyUnavailable: "Checking your iCloud account…"
        }
    }

    private var detail: String {
        switch availability {
        case .noAccount:
            "Tridge keeps your fridge in your own iCloud account so it can be shared with your household."
        case .restricted:
            "A device restriction is blocking iCloud. Ask whoever manages this device to allow it."
        case .couldNotDetermine, .temporarilyUnavailable:
            "This usually clears on its own."
        }
    }
}

/// The one-time explanation an upgraded installation owes the user.
///
/// Its acknowledgement is a separate marker from the migration itself, so
/// terminating before Continue shows it again on the next launch.
struct MigrationNoticeSheet: View {
    let acknowledge: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.ghostSpacing) {
            Text("🏠")
                .font(AppTheme.ghostArtFont)
            Text("Your fridge moved")
                .font(AppTheme.titleFont)
                .foregroundStyle(AppTheme.ink)
            Text("""
            Your current fridge was moved into Household sharing. Eaten and \
            tossed history stays only in the old local archive.
            """)
                .font(AppTheme.ghostTextFont)
                .foregroundStyle(AppTheme.mutedInk)
                .multilineTextAlignment(.center)
            Button("Continue", action: acknowledge)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brandGreen)
                .accessibilityIdentifier("migrationNotice.continue")
        }
        .padding(AppTheme.screenMargin)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
        .accessibilityIdentifier("migrationNotice")
    }
}

#if DEBUG
#Preview("Home") {
    HomeView(session: .preview(),
             coordinator: AccountSessionCoordinator(syncMonitor: StoreScopedSyncMonitor()))
}

#Preview("Launch") {
    LaunchStatusView(message: "Finishing iCloud setup…", showsProgress: true)
}
#endif
