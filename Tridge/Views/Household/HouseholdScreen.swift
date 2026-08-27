import CloudKit
import SwiftUI

/// The one screen for fridges: which ones this account can reach, which is
/// active, what the owner may do with the active one, and how synchronization
/// is doing.
///
/// It deliberately has no Manage Sharing action and no individual-member
/// removal (ADR 0012). Ownership is read from the persistent store the
/// Household lives in — private means owned, shared means received — never from
/// an optional participant field, and state is always spelled out in text as
/// well as symbol so nothing depends on colour alone.
struct HouseholdScreen: View {
    let coordinator: AccountSessionCoordinator

    @State private var renameDraft: String?
    @State private var showLeaveConfirmation = false
    @State private var showStopWarning = false
    @State private var showStopConfirmation = false
    @State private var showEraseConfirmation = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            Section("Your fridges") {
                ForEach(coordinator.households) { household in
                    householdRow(household)
                }
            }

            if let active = coordinator.activeHousehold {
                if active.ownership == .owned {
                    ownerSection(active)
                } else {
                    memberSection
                }
            }

            if coordinator.invitations.status != .idle {
                invitationSection
            }

            dataSection

            Section {
                SyncStatusRow(status: coordinator.syncStatus)
            } footer: {
                Text("""
                Changes save on this device first and sync to your household \
                when iCloud catches up.
                """)
            }
        }
        .navigationTitle("Household")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("household.screen")
        .alert("Rename fridge", isPresented: renameBinding) {
            TextField("Fridge name", text: Binding(get: { renameDraft ?? "" },
                                                   set: { renameDraft = $0 }))
                .accessibilityIdentifier("household.renameField")
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameDraft = nil }
        } message: {
            Text("Everyone in this fridge sees the new name.")
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteHousehold() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog("Erase the old inventory file?", isPresented: $showEraseConfirmation,
                            titleVisibility: .visible) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            This removes the database the previous version of Tridge kept on             this iPhone, including eaten and tossed history and old receipt             text. Your current fridges are not affected.
            """)
        }
        .sheet(isPresented: exportSheetBinding) {
            if let url = coordinator.exportedDocumentURL {
                ExportShareSheet(url: url) { coordinator.clearExportedDocument() }
            }
        }
        .sheet(isPresented: shareSheetBinding) {
            if let item = coordinator.preparedShare {
                ShareInvitationSheet(item: item) { coordinator.clearPreparedShare() }
            }
        }
        // Two steps on purpose: the first states the limitation, the second is
        // the destructive button. Neither ever claims that a member's device
        // has finished uploading.
        .alert("Stop sharing this fridge?", isPresented: $showStopWarning) {
            Button("Continue") { showStopConfirmation = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            You'll keep everything this iPhone can see right now. Anyone you             shared with loses access.
            """)
        }
        .alert("Keep only what's here?", isPresented: $showStopConfirmation) {
            Button("Stop Anyway", role: .destructive) { stopSharing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Only changes already synced to this device will be kept. Changes             still offline on someone else's device may be lost. Ask everyone to             open Tridge online before you stop sharing.
            """)
        }
        .confirmationDialog("Leave this fridge?", isPresented: $showLeaveConfirmation,
                            titleVisibility: .visible) {
            Button("Leave", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            It disappears from your devices. The person who started it keeps             everything in it — leaving deletes nothing for them.
            """)
        }
        .alert("Couldn't do that", isPresented: failureBinding) {
            Button("OK", role: .cancel) { coordinator.clearHouseholdFailure() }
        } message: {
            Text(coordinator.householdFailure?.message ?? "")
        }
    }

    // MARK: - Fridges

    private func householdRow(_ household: HouseholdSnapshot) -> some View {
        Button {
            coordinator.selectHousehold(household.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(household.name)
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle(for: household))
                        .font(AppTheme.countFont)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                Spacer()
                if household.id == coordinator.activeHouseholdID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppTheme.brandGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Transitions close command admission for a Household, so a row cannot
        // be tapped into a second switch while one is running.
        .disabled(coordinator.isHouseholdActionInFlight)
        .accessibilityIdentifier("household.row.\(household.id.uuidString)")
        .accessibilityLabel(accessibilityLabel(for: household))
        .accessibilityAddTraits(household.id == coordinator.activeHouseholdID ? [.isSelected] : [])
    }

    private func subtitle(for household: HouseholdSnapshot) -> String {
        HouseholdRowText.subtitle(for: household)
    }

    private func accessibilityLabel(for household: HouseholdSnapshot) -> String {
        HouseholdRowText.accessibilityLabel(
            for: household, isActive: household.id == coordinator.activeHouseholdID)
    }

    // MARK: - Owner actions

    /// Only the Household owner sees these. A member's screen has no rename, no
    /// share, and no invitation control at all.
    @ViewBuilder
    private func ownerSection(_ household: HouseholdSnapshot) -> some View {
        Section("This fridge") {
            Button("Rename…") { renameDraft = household.name }
                .accessibilityIdentifier("household.rename")

            Button(household.isShared ? "Send Invite…" : "Share Fridge…") {
                Task { await coordinator.prepareShare(for: household.id) }
            }
            .accessibilityIdentifier("household.share")

            if household.isShared {
                Button("Stop Sharing & Keep My Fridge…", role: .destructive) {
                    showStopWarning = true
                }
                .disabled(!coordinator.canRunDestructiveShareAction)
                .accessibilityIdentifier("household.stopSharing")

                Button("Delete Shared Fridge for Everyone…", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(!coordinator.canRunDestructiveShareAction)
                .accessibilityIdentifier("household.deleteShared")
            } else {
                // Never an implicit Stop Sharing: this appears only while there
                // is no share at all.
                Button("Delete Fridge…", role: .destructive) { showDeleteConfirmation = true }
                    .disabled(!coordinator.canRunDestructiveShareAction)
                    .accessibilityIdentifier("household.delete")
            }
        } footer: {
            if coordinator.pendingLifecycleTransition?.phase == .privateDeleteAwaitingCloud {
                // Not "deleted": the local graph is gone, but that only queued
                // an export. Completion waits until iCloud confirms absence.
                Text("Deleting from iCloud…")
                    .accessibilityIdentifier("household.deletingFromCloud")
            } else if coordinator.pendingLifecycleTransition != nil {
                Text("Finishing a change to this fridge…")
                    .accessibilityIdentifier("household.pendingTransition")
            } else if coordinator.householdsWithStaleShareTitle.contains(household.id) {
                // Honest rather than silent: the saved invitation still carries
                // the old name, and Send Invite writes it again before it will
                // present anything.
                Text("The invitation still shows this fridge's old name. Send Invite to update it.")
                    .accessibilityIdentifier("household.staleShareTitle")
            } else {
                Text("Everyone you invite can see and change this fridge. Only you can invite people.")
            }
        }
        .disabled(coordinator.isHouseholdActionInFlight)
    }

    /// A member's only lifecycle action. There is no rename, no invitation, no
    /// Manage Sharing, and no second system-UI leave path (ADR 0012).
    @ViewBuilder
    private var memberSection: some View {
        Section("This fridge") {
            Button("Leave Household…", role: .destructive) { showLeaveConfirmation = true }
                .accessibilityIdentifier("household.leave")
        } footer: {
            Text("The person who started this fridge keeps it. Leaving deletes nothing for them.")
        }
        .disabled(coordinator.isHouseholdActionInFlight)
    }

    // MARK: - Data rights

    /// The honest data-controls section. Each action says exactly what it does
    /// and to what: export copies, deletion removes a Household, Clear All only
    /// moves the inventory frontier, Leave removes access, and the legacy
    /// erasure is device-local.
    @ViewBuilder
    private var dataSection: some View {
        Section("Data") {
            ForEach(coordinator.households) { household in
                Button("Export \"\(household.name)\"…") {
                    Task { await coordinator.exportHousehold(household.id) }
                }
                .accessibilityIdentifier("household.export.\(household.id.uuidString)")
            }
            if coordinator.hasLegacyArchive {
                Button("Erase Old Local Inventory…", role: .destructive) {
                    showEraseConfirmation = true
                }
                .accessibilityIdentifier("household.eraseLegacy")
            }
        } footer: {
            Text(coordinator.hasLegacyArchive
                 ? """
                 Export writes a file of everything in a fridge, including items \
                 you've finished. Erasing the old local inventory removes the \
                 previous version's database from this iPhone only.
                 """
                 : """
                 Export writes a file of everything in a fridge, including items \
                 you've finished.
                 """)
        }
        .disabled(coordinator.isHouseholdActionInFlight)
    }

    // MARK: - Invitation status

    @ViewBuilder
    private var invitationSection: some View {
        Section("Invitation") {
            Text(InvitationStatusText.message(for: coordinator.invitations.status))
                .accessibilityIdentifier("household.invitationStatus")
            if coordinator.invitations.canRetry {
                Button("Try Again") { coordinator.invitations.retry() }
                    .accessibilityIdentifier("household.invitationRetry")
            }
            if InvitationStatusText.isSettled(coordinator.invitations.status) {
                Button("Dismiss") { coordinator.invitations.dismiss() }
                    .accessibilityIdentifier("household.invitationDismiss")
            }
        }
    }

    // MARK: - Bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameDraft != nil }, set: { if !$0 { renameDraft = nil } })
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(get: { coordinator.exportedDocumentURL != nil },
                set: { if !$0 { coordinator.clearExportedDocument() } })
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(get: { coordinator.preparedShare != nil },
                set: { if !$0 { coordinator.clearPreparedShare() } })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { coordinator.householdFailure != nil },
                set: { if !$0 { coordinator.clearHouseholdFailure() } })
    }

    private var deleteTitle: String {
        coordinator.activeHousehold?.isShared == true
            ? "Delete this fridge for everyone?"
            : "Delete this fridge?"
    }

    private var deleteMessage: String {
        let shared = coordinator.activeHousehold?.isShared == true
        let base = shared
            ? """
            Everything in it goes, for you and for everyone you shared it with.             This can't be undone.
            """
            : "Everything in it goes. This can't be undone."
        guard coordinator.hasLegacyArchive else { return base }
        // Honest about what this action does *not* cover.
        return base + " The old local inventory file stays until you erase it below."
    }

    private func deleteHousehold() {
        guard let householdID = coordinator.activeHouseholdID else { return }
        Haptics.warning()
        Task { await coordinator.deleteHousehold(householdID) }
    }

    private func erase() {
        Haptics.warning()
        Task { await coordinator.eraseLegacyArchive() }
    }

    private func stopSharing() {
        guard let householdID = coordinator.activeHouseholdID else { return }
        Haptics.warning()
        Task { await coordinator.stopSharing(householdID) }
    }

    private func leave() {
        guard let householdID = coordinator.activeHouseholdID else { return }
        Haptics.warning()
        Task { await coordinator.leaveHousehold(householdID) }
    }

    private func commitRename() {
        guard let name = renameDraft?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, let householdID = coordinator.activeHouseholdID
        else {
            renameDraft = nil
            return
        }
        renameDraft = nil
        Task { await coordinator.renameHousehold(householdID, to: name) }
    }
}

/// The invitation sheet an owner sees after the share and its title have been
/// saved.
///
/// It exists so every Send Invite is preceded by that refresh: the `ShareLink`
/// is built from a share that was just confirmed server-side, and closing the
/// sheet drops it, so the next invitation refreshes again rather than reusing a
/// share whose fridge name may have moved on.
struct ShareInvitationSheet: View {
    let item: HouseholdShareItem
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.ghostSpacing) {
                Text("🏠")
                    .font(AppTheme.ghostArtFont)
                Text(item.title)
                    .font(AppTheme.titleFont)
                    .foregroundStyle(AppTheme.ink)
                Text("""
                Choose who to invite. They can see and change everything in this \
                fridge, and only you can invite people.
                """)
                    .font(AppTheme.ghostTextFont)
                    .foregroundStyle(AppTheme.mutedInk)
                    .multilineTextAlignment(.center)
                ShareLink(item: item, preview: SharePreview(item.title)) {
                    Label("Invite People", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brandGreen)
                .accessibilityIdentifier("household.shareLink")
            }
            .padding(AppTheme.screenMargin)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("household.shareSheet")
    }
}

/// Hands the written export to the system share sheet.
///
/// The file is temporary and is deleted when this closes, so a document that
/// contains a whole fridge's history does not sit around waiting to be found.
struct ExportShareSheet: View {
    let url: URL
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.ghostSpacing) {
                Text("📄")
                    .font(AppTheme.ghostArtFont)
                Text(url.lastPathComponent)
                    .font(AppTheme.ghostTextFont)
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                Text("""
                Everything in this fridge, including items you've finished. It \
                contains no receipt text, no account details, and nothing about \
                who it's shared with.
                """)
                    .font(AppTheme.countFont)
                    .foregroundStyle(AppTheme.mutedInk)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Save or Send", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brandGreen)
                .accessibilityIdentifier("household.exportLink")
            }
            .padding(AppTheme.screenMargin)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("household.exportSheet")
    }
}

/// What each invitation state says. Separated from the view so the wording —
/// which must never expose a share URL, a zone, or a participant identity — can
/// be asserted on directly.
enum InvitationStatusText {
    static func message(for status: ShareInvitationRouter.Status) -> String {
        switch status {
        case .idle: ""
        case .waitingForStore: "Getting your fridge ready before joining…"
        case .accepting: "Joining that fridge…"
        case .accepted: "You've joined. It's in the list above — tap it to switch."
        case .failed(let failure): failure.message
        case .needsReopen: "That invitation isn't available any more. Ask for a new one."
        case .rejected: "That invitation isn't for Tridge."
        }
    }

    /// Whether the user can clear the state themselves, rather than it clearing
    /// as the work finishes.
    static func isSettled(_ status: ShareInvitationRouter.Status) -> Bool {
        switch status {
        case .accepted, .failed, .needsReopen, .rejected: true
        case .idle, .waitingForStore, .accepting: false
        }
    }
}

/// The row's wording, separated from the view so it can be asserted on
/// directly. Ownership is the store's answer, carried in the snapshot.
enum HouseholdRowText {
    static func ownership(for household: HouseholdSnapshot) -> String {
        household.ownership == .owned ? "Owned by you" : "Shared with you"
    }

    static func subtitle(for household: HouseholdSnapshot) -> String {
        let created = household.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(ownership(for: household)) · Started \(created)"
    }

    static func accessibilityLabel(for household: HouseholdSnapshot, isActive: Bool) -> String {
        "\(household.name), \(subtitle(for: household))\(isActive ? ", active fridge" : "")"
    }
}

/// Sync health as text plus a symbol. It never exposes a raw CloudKit error, a
/// share URL, or a member identity — and it never claims that another device
/// has already received a change.
struct SyncStatusRow: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: AppTheme.settingsRowIconGap) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(AppTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("household.syncStatus")
    }

    private var label: String { SyncStatusPresentation(status).label }

    private var symbol: String { SyncStatusPresentation(status).symbol }

    private var tint: Color {
        switch status {
        case .upToDate: AppTheme.brandGreen
        case .syncing, .offline: AppTheme.mutedInk
        case .needsAttention: AppTheme.soon
        }
    }
}

/// The four sync states as text plus a symbol.
///
/// A separate value so the wording can be asserted on, and so the rule that
/// every state says what it means in words — never colour alone, and never a
/// raw CloudKit error — is enforced in one place.
struct SyncStatusPresentation: Equatable {
    let label: String
    let symbol: String

    init(_ status: SyncStatus) {
        switch status {
        case .upToDate:
            label = "Up to date"
            symbol = "checkmark.icloud"
        case .syncing:
            label = "Syncing…"
            symbol = "arrow.triangle.2.circlepath.icloud"
        case .offline:
            label = "Offline — changes will sync later"
            symbol = "icloud.slash"
        case .needsAttention:
            label = "iCloud needs attention"
            symbol = "exclamationmark.icloud"
        }
    }
}
