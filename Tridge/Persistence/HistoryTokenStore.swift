import CoreData

/// Where each store's persistent-history cursor lives.
///
/// One token per persistent-store identifier, scoped by account hash: the two
/// stores advance independently, and a token from another account — or from a
/// store that was recreated — must never be mistaken for this one's. Tokens are
/// deliberately kept outside CloudKit; they describe local processing progress,
/// not shared data.
struct HistoryTokenStore {
    private let defaults: UserDefaults
    private let accountScope: AccountScopeHash

    init(accountScope: AccountScopeHash, defaults: UserDefaults = .standard) {
        self.accountScope = accountScope
        self.defaults = defaults
    }

    /// Nil before the first batch is processed, which makes the first fetch
    /// "everything so far" — the correct starting point for a fresh cache.
    func token(forStoreIdentifier identifier: String) -> NSPersistentHistoryToken? {
        guard let data = defaults.data(forKey: key(identifier)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self,
                                                       from: data)
    }

    /// Saved only after a batch has been fully applied, so an interrupted pass
    /// is retried rather than skipped.
    func save(_ token: NSPersistentHistoryToken, forStoreIdentifier identifier: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                           requiringSecureCoding: true)
        else { return }
        defaults.set(data, forKey: key(identifier))
    }

    func clear(forStoreIdentifier identifier: String) {
        defaults.removeObject(forKey: key(identifier))
    }

    private func key(_ identifier: String) -> String {
        accountScope.defaultsKey("historyToken.\(identifier)")
    }
}
