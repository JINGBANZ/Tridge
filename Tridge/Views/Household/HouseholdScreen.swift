import SwiftUI

/// The one screen for fridges: which ones this account can reach, which is
/// active, and how synchronization is doing.
///
/// It deliberately has no Manage Sharing action and no individual-member
/// removal (ADR 0012). Ownership is read from the persistent store the
/// Household lives in — private means owned, shared means received — never from
/// an optional participant field, and state is always spelled out in text as
/// well as symbol so nothing depends on colour alone.
struct HouseholdScreen: View {
    let coordinator: AccountSessionCoordinator

    var body: some View {
        List {
            Section("Your fridges") {
                ForEach(coordinator.households) { household in
                    householdRow(household)
                }
            }

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
    }

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
