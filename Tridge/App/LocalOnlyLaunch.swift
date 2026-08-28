#if DEBUG
import CloudKit
import Foundation

/// A Debug-only launch mode that opens Tridge's two stores locally, with no
/// CloudKit container at all.
///
/// It exists because `CKContainer(identifier:)` traps in a process that has no
/// iCloud entitlement, so an unsigned Simulator build cannot reach Home until
/// `iCloud.com.tridge.app` is provisioned (wiki/release-handoff.md). This lets
/// the whole interface — Home, the sheets, the Household screen, export, the
/// legacy erasure — be exercised before that happens.
///
/// Everything it changes is honest about itself: the stores are the real ones
/// with mirroring off, the account scope is a fixed local digest, and every
/// sharing action reports that sharing is unavailable rather than pretending.
/// Run it with `-localOnlyStores` in the scheme's launch arguments.
enum LocalOnlyLaunch {
    static let argument = "-localOnlyStores"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// A fixed digest, so the local directories are stable across launches and
    /// cannot collide with a real account's.
    private static let scope = AccountScopeHash(digest: String(repeating: "0", count: 64))!

    @MainActor
    static func coordinator() -> AccountSessionCoordinator {
        AccountSessionCoordinator(
            identity: FixedAccountIdentity(scope: scope),
            syncMonitor: LocalOnlySyncMonitor(),
            makePersistence: { scope in
                let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                return try await PersistenceController.load(
                    configuration: .localOnly(accountScope: scope, baseDirectory: base))
            },
            makeSharing: { _ in UnavailableHouseholdSharing() })
    }
}

/// Reports the local truth for a stack with no mirroring.
///
/// `.localOnly` leaves `cloudKitContainerOptions` nil, so the container emits no
/// setup or import event ever. The real monitor would therefore hold the
/// bootstrap barrier closed forever and the launch would sit on "Finishing
/// iCloud setup…" — and `canRunDestructiveShareAction` would refuse Stop
/// Sharing and Delete for the same reason. There is nothing to import and
/// nothing pending to export here, so the honest answers are "already imported"
/// and "up to date".
@MainActor
private final class LocalOnlySyncMonitor: SyncStatusProviding {
    var currentStatus: SyncStatus { .upToDate }

    /// One value, then finished: the status cannot change without a container.
    var statusUpdates: AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            continuation.yield(.upToDate)
            continuation.finish()
        }
    }

    var onRecoveryNeeded: (@MainActor (SyncRecoveryNeed, String) -> Void)?

    func updateAccountState(_ state: SyncAccountState) {}
    func prepareSession(generation: AccountGeneration) {}
    func activateSession(generation: AccountGeneration, storeIdentifiers: Set<String>) {}
    func endSession(generation: AccountGeneration) {}

    func hasCompletedInitialImport(generation: AccountGeneration,
                                   storeIdentifier: String) -> Bool { true }

    func waitForInitialImport(generation: AccountGeneration,
                              storeIdentifier: String) async -> Bool { true }

    func waitForNextSuccessfulExport(generation: AccountGeneration,
                                     storeIdentifier: String) async -> Bool { true }
}

/// Answers with one scope, without asking CloudKit who is signed in.
private struct FixedAccountIdentity: AccountIdentityProviding {
    let scope: AccountScopeHash

    func validateCurrentAccountScope() async throws -> AccountScopeHash { scope }
}

/// Reports that sharing is unavailable, for every operation.
///
/// There is no container to share into, so the honest answer is a failure the
/// Household screen can show — never a fake success that would make an
/// invitation look like it had been sent.
@MainActor
private final class UnavailableHouseholdSharing: HouseholdSharing {
    private var failure: HouseholdActionFailure {
        HouseholdActionFailure(reason: .unavailable,
                               message: "Sharing needs iCloud, which isn't available in this build.",
                               diagnosticID: "sharing.localOnly")
    }

    /// Known-empty rather than unknown: there is no container, so nothing is
    /// shared and that is a certain answer.
    func sharedHouseholdIDs(among householdIDs: [UUID]) async -> Set<UUID>? { [] }

    func prepareShare(for householdID: UUID, title: String) async throws -> HouseholdShareItem {
        throw failure
    }

    func accept(_ metadata: any ShareInvitationMetadata) async throws { throw failure }

    func purgeZone(of householdID: UUID, in scope: HouseholdDatabaseScope) async throws {
        // Nothing is mirrored, so there is no zone. The caller's local-absence
        // check is what actually removes the Household.
    }

    func capturedRecords(of householdID: UUID) async throws -> [CapturedCloudKitRecord] { [] }

    func confirmRecordsAbsent(_ records: [CapturedCloudKitRecord]) async throws -> Bool { true }
}
#endif
