import Foundation

/// Why an upgrade could not finish. Retryable, and content-free: a stage and an
/// error code, never an item name, a household name, or a path.
struct LegacyMigrationFailure: Error, Equatable {
    let diagnosticID: String

    init(diagnosticID: String) {
        self.diagnosticID = diagnosticID
    }

    init(_ error: Error) {
        switch error {
        case let read as LegacyInventoryArchive.ReadError:
            self.init(diagnosticID: read.diagnosticID)
        case let issue as RecordIntegrityIssue:
            self.init(diagnosticID: "legacy.row.\(issue.category.rawValue)")
        case let write as PersistenceController.LegacyImportError:
            self.init(diagnosticID: write.diagnosticID)
        default:
            self.init(diagnosticID: "legacy.unresolved")
        }
    }
}

/// The one-time upgrade from the shipping SwiftData build into Household
/// sharing (wiki/household-sharing.md → "Upgrade from the shipping build").
///
/// It owns the three things the upgrade must get right and nothing else:
/// cleaning the previous build's side effects before iCloud is even consulted,
/// deciding whether an archive is still waiting, and moving every active row
/// into one owned Household exactly once. Whether the archive stays on disk is
/// not a decision it makes — it never writes to it.
struct LegacyInventoryUpgrade {
    private let archive: any LegacyInventoryArchiveReading
    private let markers: UpgradeMarkers
    private let effects: any LegacyEffectsCleaning
    /// Read once per migration so a single calendar/time-zone snapshot converts
    /// every row, rather than a launch that spans midnight splitting one archive
    /// across two days.
    private let calendar: @Sendable () -> Calendar

    init(archive: any LegacyInventoryArchiveReading = LegacyInventoryArchive(),
         markers: UpgradeMarkers = UpgradeMarkers(),
         effects: any LegacyEffectsCleaning = UserNotificationLegacyEffects(),
         calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.archive = archive
        self.markers = markers
        self.effects = effects
        self.calendar = calendar
    }

    /// Step 1, before the iCloud account is checked or any account-scoped store
    /// is opened: reminders scheduled by the previous build must stop firing for
    /// an inventory that is moving, even on an installation that is signed out
    /// or restricted and will never reach the migration itself.
    func cleanUpLegacyEffectsIfNeeded() {
        guard !markers.hasCleanedLegacyEffects else { return }
        effects.clearScheduledAndDeliveredNotifications()
        markers.recordLegacyEffectsCleanup()
    }

    /// Whether an archive is still waiting to be migrated. False once the
    /// migration completed, which is what stops a later iCloud account from
    /// receiving the same archive.
    var isPending: Bool { !markers.hasMigratedLegacyInventory && archive.exists }

    /// Whether the user still has to be told their fridge moved. Independent of
    /// the migration marker, so terminating before Continue shows it again.
    var needsNotice: Bool {
        markers.hasMigratedLegacyInventory && !markers.hasAcknowledgedMigrationNotice
    }

    /// Records that the user read the notice. Its own marker, so terminating
    /// before Continue shows it again on the next launch.
    func acknowledgeNotice() {
        markers.recordMigrationNoticeAcknowledgement()
    }

    /// Reads the archive, validates every active row, and writes them into
    /// `householdID` in one transaction.
    ///
    /// The migration is recorded only after the write can be refetched, so a
    /// crash between the two repeats the idempotent write rather than retiring
    /// an archive that never landed. Returns how many rows the archive had to
    /// move, which is stable across retries — unlike how many this attempt
    /// happened to insert.
    func migrate(into householdID: UUID, accountScope: AccountScopeHash,
                 using controller: PersistenceController) async throws -> Int {
        do {
            let rows = try archive.readActiveRows()
            let drafts = try LegacyInventoryPlanner.plan(rows, calendar: calendar())
            _ = try await controller.importLegacyInventory(drafts, into: householdID)
            markers.recordLegacyMigration(accountScope: accountScope, householdID: householdID)
            if drafts.isEmpty {
                // Nothing moved, so there is nothing to explain. Settling the
                // notice here rather than leaving it pending is what keeps a
                // fresh installation — whose store file exists because the app
                // created it, not because it holds a legacy fridge — from being
                // told its fridge was moved.
                markers.recordMigrationNoticeAcknowledgement()
            }
            return drafts.count
        } catch {
            throw LegacyMigrationFailure(error)
        }
    }

    /// The installation is fully on the sharing stack: the new stores opened,
    /// legacy effects were cleaned, and nothing is waiting to be migrated.
    func recordCompletionIfFinished() {
        guard markers.hasCleanedLegacyEffects, !isPending else { return }
        markers.recordPersistenceGeneration()
    }
}
