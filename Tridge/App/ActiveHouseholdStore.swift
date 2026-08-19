import Foundation

/// Remembers which Household the user last selected, per account.
///
/// Only the UUID is persisted, and it is validated against the accessible
/// Households on every launch — a household that was left, revoked, purged, or
/// deleted must fall through to the deterministic fallback rather than being
/// restored from a stale default. The key is account-scoped, so signing into a
/// second account never reads the first one's selection. Selection is local and
/// deliberately does not sync to another device.
struct ActiveHouseholdStore {
    private static let key = "activeHouseholdID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func savedID(for accountScope: AccountScopeHash) -> UUID? {
        guard let raw = defaults.string(forKey: accountScope.defaultsKey(Self.key)) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    func save(_ id: UUID, for accountScope: AccountScopeHash) {
        defaults.set(id.uuidString, forKey: accountScope.defaultsKey(Self.key))
    }

    func clear(for accountScope: AccountScopeHash) {
        defaults.removeObject(forKey: accountScope.defaultsKey(Self.key))
    }
}
