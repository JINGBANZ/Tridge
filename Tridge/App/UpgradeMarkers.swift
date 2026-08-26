import Foundation

/// Installation-wide records of what the upgrade to Household sharing has
/// already done.
///
/// Each responsibility has its own marker, because completing one never implies
/// another happened: reminders may be cleaned while iCloud is signed out, the
/// migration may succeed before its notice is read, and the notice may be
/// dismissed long after the stack is on generation 2. Nothing here is
/// account-scoped — the archive belongs to the installation, so migrating it
/// once must stop a later iCloud account from receiving it again.
///
/// Legacy *erasure* deliberately has no marker: the archive files themselves are
/// the record, so Erase Old Local Inventory stays available exactly until they
/// are gone (wiki/household-sharing.md → "Upgrade from the shipping build").
struct UpgradeMarkers {
    /// The Core Data + CloudKit sharing stack. Generation 1 was SwiftData.
    static let currentGeneration = 2

    private enum Key {
        static let legacyEffectsCleanup = "legacyEffectsCleanupGeneration"
        static let legacyMigration = "legacyMigrationGeneration"
        static let migrationAccountScope = "legacyMigrationDestinationAccountScope"
        static let migrationHouseholdID = "legacyMigrationDestinationHouseholdID"
        static let migrationNoticeAcknowledged = "legacyMigrationNoticeAcknowledgedGeneration"
        static let persistence = "persistenceGeneration"
    }

    /// Where an archive was migrated. Kept for diagnostics and for proving the
    /// binding in tests; the migration gate is the generation marker alone.
    struct MigrationDestination: Equatable {
        let accountScope: AccountScopeHash
        let householdID: UUID
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Legacy side effects

    var hasCleanedLegacyEffects: Bool { isCurrent(Key.legacyEffectsCleanup) }

    func recordLegacyEffectsCleanup() { markCurrent(Key.legacyEffectsCleanup) }

    // MARK: - Inventory migration

    var hasMigratedLegacyInventory: Bool { isCurrent(Key.legacyMigration) }

    var migrationDestination: MigrationDestination? {
        guard hasMigratedLegacyInventory,
              let digest = defaults.string(forKey: Key.migrationAccountScope),
              let scope = AccountScopeHash(digest: digest),
              let raw = defaults.string(forKey: Key.migrationHouseholdID),
              let householdID = UUID(uuidString: raw)
        else { return nil }
        return MigrationDestination(accountScope: scope, householdID: householdID)
    }

    /// Written only once the migration's own rows can be refetched, and with
    /// its destination, so a later account cannot inherit the same archive.
    func recordLegacyMigration(accountScope: AccountScopeHash, householdID: UUID) {
        defaults.set(accountScope.value, forKey: Key.migrationAccountScope)
        defaults.set(householdID.uuidString, forKey: Key.migrationHouseholdID)
        markCurrent(Key.legacyMigration)
    }

    // MARK: - Migration notice

    var hasAcknowledgedMigrationNotice: Bool { isCurrent(Key.migrationNoticeAcknowledged) }

    /// Set only when the user taps Continue, so terminating first shows the
    /// notice again.
    func recordMigrationNoticeAcknowledgement() { markCurrent(Key.migrationNoticeAcknowledged) }

    // MARK: - Persistence generation

    var isOnCurrentPersistenceGeneration: Bool { isCurrent(Key.persistence) }

    /// Set only after the new stack opened, legacy effects were cleaned, and any
    /// required migration succeeded. A crash before this repeats only the
    /// incomplete idempotent work.
    func recordPersistenceGeneration() { markCurrent(Key.persistence) }

    private func isCurrent(_ key: String) -> Bool {
        defaults.integer(forKey: key) >= Self.currentGeneration
    }

    private func markCurrent(_ key: String) {
        defaults.set(Self.currentGeneration, forKey: key)
    }
}
