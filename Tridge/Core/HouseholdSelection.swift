import Foundation

public enum HouseholdSelectionOutcome: Equatable, Sendable {
    case select(UUID)
    /// No household exists and the account has finished its first import, so
    /// this really is a new account.
    case createDefaultHousehold
    /// The private store is empty but its first CloudKit import has not
    /// succeeded yet — creating a household now would duplicate one that is
    /// still arriving.
    case waitForInitialImport
}

/// Chooses the Active Household deterministically, so an account change, a
/// revoked share, or a deleted household always lands somewhere predictable.
public enum HouseholdSelection {
    public static let defaultHouseholdName = "My Fridge"

    public static func choose(saved: UUID?, available: [HouseholdSnapshot],
                              hasCompletedInitialImport: Bool) -> HouseholdSelectionOutcome {
        if let saved, available.contains(where: { $0.id == saved }) {
            return .select(saved)
        }
        if let oldestOwned = oldest(available.filter { $0.ownership == .owned }) {
            return .select(oldestOwned.id)
        }
        if let oldestReceived = oldest(available.filter { $0.ownership == .received }) {
            return .select(oldestReceived.id)
        }
        return hasCompletedInitialImport ? .createDefaultHousehold : .waitForInitialImport
    }

    private static func oldest(_ households: [HouseholdSnapshot]) -> HouseholdSnapshot? {
        households.min { left, right in
            left.createdAt == right.createdAt
                ? UUIDOrder.isBefore(left.id, right.id)
                : left.createdAt < right.createdAt
        }
    }
}
