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
    static func coordinator(syncMonitor: any SyncStatusProviding) -> AccountSessionCoordinator {
        AccountSessionCoordinator(
            identity: FixedAccountIdentity(scope: scope),
            syncMonitor: syncMonitor,
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

    func sharedHouseholdIDs(among householdIDs: [UUID]) async -> Set<UUID> { [] }

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
