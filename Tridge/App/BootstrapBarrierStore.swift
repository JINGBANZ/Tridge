import Foundation

/// Remembers that one private store finished a successful first CloudKit
/// import.
///
/// The marker is keyed by account scope *and* private-store identifier: a store
/// that was recreated has not proven anything, and another account's marker
/// must never satisfy this account's barrier. Once set, an empty private store
/// is evidence that the account really has no household, so `My Fridge` may be
/// created without duplicating one that is still arriving.
struct BootstrapBarrierStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasCompletedInitialImport(accountScope: AccountScopeHash,
                                   privateStoreIdentifier: String) -> Bool {
        defaults.bool(forKey: key(accountScope, privateStoreIdentifier))
    }

    func recordInitialImport(accountScope: AccountScopeHash, privateStoreIdentifier: String) {
        defaults.set(true, forKey: key(accountScope, privateStoreIdentifier))
    }

    private func key(_ accountScope: AccountScopeHash, _ privateStoreIdentifier: String) -> String {
        accountScope.defaultsKey("initialPrivateImportSucceeded.\(privateStoreIdentifier)")
    }
}
