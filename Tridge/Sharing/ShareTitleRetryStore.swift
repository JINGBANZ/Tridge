import Foundation

/// Remembers that a Household's share title could not be written.
///
/// A rename saves the Household first and then updates `CKShare`'s title; the
/// second write can fail on its own. The marker is account-scoped and survives
/// termination, so the Household screen can say the invitation name is out of
/// date rather than silently offering an invitation that would show the old
/// one. `prepareShare` reconciles the title before every invitation, so the
/// marker is cleared by the next successful Send Invite.
struct ShareTitleRetryStore {
    private let defaults: UserDefaults
    private let accountScope: AccountScopeHash

    init(accountScope: AccountScopeHash, defaults: UserDefaults = .standard) {
        self.accountScope = accountScope
        self.defaults = defaults
    }

    func needsRetry(_ householdID: UUID) -> Bool {
        defaults.bool(forKey: key(householdID))
    }

    func recordFailure(_ householdID: UUID) {
        defaults.set(true, forKey: key(householdID))
    }

    func clear(_ householdID: UUID) {
        defaults.removeObject(forKey: key(householdID))
    }

    private func key(_ householdID: UUID) -> String {
        accountScope.defaultsKey("shareTitleNeedsRetry.\(householdID.uuidString)")
    }
}
