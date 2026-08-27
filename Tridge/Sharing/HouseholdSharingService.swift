import CloudKit
import CoreData

/// Why a Household-level sharing or lifecycle action could not be completed.
///
/// Content-free by contract: a category and an opaque diagnostic id, never a
/// share URL, a participant identity, a CloudKit record payload, or a Household
/// name.
struct HouseholdActionFailure: Error, Equatable, Identifiable {
    enum Reason: Equatable {
        /// The Household is not in either of this account's stores any more.
        case householdUnavailable
        /// The action is owner-only and this Household was received.
        case notOwner
        /// CloudKit refused the write for this account.
        case permissionDenied
        /// A CloudKit platform cap — participants per share, zones per
        /// container, storage quota. Retryable, and nothing was changed.
        case limitReached
        /// Account or network is not currently usable.
        case unavailable
        /// Anything else. Retryable; the id is safe to quote.
        case unresolved
    }

    let reason: Reason
    let message: String
    let diagnosticID: String

    var id: String { diagnosticID }

    init(reason: Reason, message: String, diagnosticID: String) {
        self.reason = reason
        self.message = message
        self.diagnosticID = diagnosticID
    }

    init(_ error: Error, stage: String) {
        switch error {
        case let failure as HouseholdActionFailure:
            self = failure
        case let repository as InventoryRepositoryError:
            self = Self(repository: repository, stage: stage)
        case let cloudKit as CKError:
            self = Self(cloudKit: cloudKit, stage: stage)
        case let erase as LegacyArchiveEraser.Failure:
            self.init(reason: .unresolved,
                      message: "Tridge couldn't remove the old inventory file. Try again.",
                      diagnosticID: erase.diagnosticID)
        default:
            let details = error as NSError
            self.init(reason: .unresolved, message: Self.retryMessage,
                      diagnosticID: "\(stage).\(details.domain).\(details.code)")
        }
    }

    private init(repository failure: InventoryRepositoryError, stage: String) {
        switch failure {
        case .householdUnavailable:
            self.init(reason: .householdUnavailable,
                      message: "That fridge isn't available on this device any more.",
                      diagnosticID: "\(stage).household")
        case .householdNotOwned:
            self.init(reason: .notOwner,
                      message: "Only the person who started this fridge can do that.",
                      diagnosticID: "\(stage).owner")
        case .permissionDenied:
            self.init(reason: .permissionDenied,
                      message: "You no longer have permission to change this household.",
                      diagnosticID: "\(stage).permission")
        default:
            self.init(reason: .unresolved, message: Self.retryMessage,
                      diagnosticID: "\(stage).command")
        }
    }

    private init(cloudKit error: CKError, stage: String) {
        let diagnosticID = "\(stage).ck.\(error.errorCode)"
        switch error.code {
        case .limitExceeded, .quotaExceeded, .tooManyParticipants:
            // Nothing was changed, so this really is "try again later" rather
            // than a state the user has to repair. Tridge adds no participant
            // cache or parallel quota counter to predict it.
            self.init(reason: .limitReached,
                      message: "iCloud can't take any more right now. Try again later.",
                      diagnosticID: diagnosticID)
        case .permissionFailure, .notAuthenticated:
            self.init(reason: .permissionDenied,
                      message: "You no longer have permission to change this household.",
                      diagnosticID: diagnosticID)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy:
            self.init(reason: .unavailable,
                      message: "iCloud isn't reachable right now. Try again in a moment.",
                      diagnosticID: diagnosticID)
        default:
            self.init(reason: .unresolved, message: Self.retryMessage, diagnosticID: diagnosticID)
        }
    }

    private static let retryMessage = "Tridge couldn't finish that. Try again."
}

/// The CloudKit share operations Tridge performs, behind a protocol so the UI
/// and the lifecycle flows can be driven by a fake before any live container
/// exists.
///
/// Everything here is main-actor: `NSPersistentCloudKitContainer`'s sharing
/// calls take managed objects, and the ones Tridge passes come from the view
/// context.
@MainActor
protocol HouseholdSharing: AnyObject {
    /// Which of these Households currently have a `CKShare`.
    ///
    /// Share metadata never appears in persistent history, so share status is
    /// refreshed deliberately — after container events, invitation activity,
    /// account changes, and foreground activation — rather than observed.
    func sharedHouseholdIDs(among householdIDs: [UUID]) async -> Set<UUID>

    /// The Household's current share, refreshed from the container. Nil when it
    /// has never been shared.
    func currentShare(for householdID: UUID) async throws -> CKShare?

    /// Creates the Household's share if it has none, then makes sure the saved
    /// share title matches `title` before returning it.
    ///
    /// The title write has to succeed: a reused invitation must never knowingly
    /// display a stale fridge name.
    func prepareShare(for householdID: UUID, title: String) async throws -> HouseholdShareItem

    /// Accepts one invitation into this account's shared store.
    func accept(_ metadata: any ShareInvitationMetadata) async throws

    /// Purges a Household's record zone and its local graph.
    ///
    /// A member leaving purges their own shared-store mirror; an owner stopping
    /// or deleting purges the shared zone for everyone. Apple's API removes
    /// **both** the CloudKit records and the local Core Data graph, which is
    /// why a copy that must survive is made *before* this is called.
    ///
    /// Reports whether the server zone was already gone, because that is a
    /// cleanup path rather than a completed purge.
    func purgeZone(of householdID: UUID,
                   in scope: HouseholdDatabaseScope) async throws -> PurgeOutcome

    /// The CloudKit records this Household's local graph currently maps to.
    ///
    /// Captured *before* the graph is deleted, because afterwards there is
    /// nothing left to ask. Objects with no mapped record simply do not appear:
    /// they need only local deletion.
    func capturedRecords(of householdID: UUID) async throws -> [CapturedCloudKitRecord]

    /// Whether every captured record is really gone from the private database.
    ///
    /// A local Core Data delete only queues an export, so this read is what
    /// makes "deleted" a claim rather than a hope. Completion requires every
    /// result to be unknown-item; a record that is still there, or any other
    /// error, leaves the deletion pending.
    func confirmRecordsAbsent(_ records: [CapturedCloudKitRecord]) async throws -> Bool
}

/// What a zone purge found.
enum PurgeOutcome: Equatable {
    case purged
    /// The zone is not on the server — already purged, deleted by its owner, or
    /// never created. The local graph still has to be verified absent.
    case zoneAlreadyMissing
}

/// The production implementation over `NSPersistentCloudKitContainer`.
@MainActor
final class CloudKitHouseholdSharing: HouseholdSharing {
    /// The Tridge share type recorded on every share Tridge creates.
    static let shareType = "com.tridge.app.household"

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func sharedHouseholdIDs(among householdIDs: [UUID]) async -> Set<UUID> {
        var byObjectID: [NSManagedObjectID: UUID] = [:]
        for store in [persistence.privateStore, persistence.sharedStore] {
            let request = HouseholdRecord.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", householdIDs as NSArray)
            request.affectedStores = [store]
            for record in (try? persistence.viewContext.fetch(request)) ?? [] {
                if let id = record.id { byObjectID[record.objectID] = id }
            }
        }
        guard !byObjectID.isEmpty,
              let shares = try? persistence.container.fetchShares(matching: Array(byObjectID.keys))
        else { return [] }
        return Set(shares.keys.compactMap { byObjectID[$0] })
    }

    func currentShare(for householdID: UUID) async throws -> CKShare? {
        let record = try ownedRecord(householdID)
        return try persistence.container.fetchShares(matching: [record.objectID])[record.objectID]
    }

    func prepareShare(for householdID: UUID, title: String) async throws -> HouseholdShareItem {
        let record = try ownedRecord(householdID)
        let container = CKContainer(identifier: TridgeCloudKit.containerIdentifier)

        var share: CKShare
        if let existing = try persistence.container
            .fetchShares(matching: [record.objectID])[record.objectID] {
            share = existing
        } else {
            // Moves the Household's related graph into the share's record zone.
            // Its items, operations, and merge claims stay in the same store.
            let result = try await persistence.container.share([record], to: nil)
            share = result.1
        }

        if share[CKShare.SystemFieldKey.title] as? String != title {
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = Self.shareType as CKRecordValue
            // The write must land before ShareLink is offered, so this is
            // awaited rather than fired and forgotten.
            share = try await persistence.container.persistUpdatedShare(
                share, in: persistence.privateStore)
        }
        return HouseholdShareItem(share: share, container: container, title: title)
    }

    func accept(_ metadata: any ShareInvitationMetadata) async throws {
        guard let metadata = metadata as? CKShare.Metadata else {
            // Only the real thing can be handed to CloudKit; a stand-in reaching
            // here would mean the router was bound to the wrong adapter.
            throw HouseholdActionFailure(reason: .unresolved,
                                         message: "That invitation couldn't be opened.",
                                         diagnosticID: "invitation.metadata")
        }
        let container = persistence.container
        let store = persistence.sharedStore
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.acceptShareInvitations(from: [metadata], into: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func purgeZone(of householdID: UUID,
                   in scope: HouseholdDatabaseScope) async throws -> PurgeOutcome {
        let store = persistence.store(for: scope)
        guard let record = try record(householdID, in: store),
              let share = try persistence.container
                  .fetchShares(matching: [record.objectID])[record.objectID]
        else {
            // No share means no zone to purge; the caller still verifies that
            // nothing of the Household is left locally.
            return .zoneAlreadyMissing
        }

        let zoneID = share.recordID.zoneID
        let container = persistence.container
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                container.purgeObjectsAndRecordsInZone(with: zoneID, in: store) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return .purged
        } catch let error as CKError where Self.meansZoneIsGone(error) {
            // Proof only that the remote zone is absent. The local check that
            // follows is what actually finishes the transition.
            return .zoneAlreadyMissing
        }
    }

    func capturedRecords(of householdID: UUID) async throws -> [CapturedCloudKitRecord] {
        guard let household = try record(householdID, in: persistence.privateStore) else {
            return []
        }
        var objectIDs: [NSManagedObjectID] = [household.objectID]
        objectIDs += household.itemMerges.map(\.objectID)
        objectIDs += household.clearEvents.map(\.objectID)
        for item in household.items {
            objectIDs.append(item.objectID)
            objectIDs += item.stockChanges.map(\.objectID)
        }

        return persistence.container.recordIDs(for: objectIDs).values.map {
            CapturedCloudKitRecord(recordName: $0.recordName, zoneName: $0.zoneID.zoneName,
                                   zoneOwnerName: $0.zoneID.ownerName)
        }
    }

    func confirmRecordsAbsent(_ records: [CapturedCloudKitRecord]) async throws -> Bool {
        guard !records.isEmpty else { return true }
        let database = CKContainer(identifier: TridgeCloudKit.containerIdentifier)
            .privateCloudDatabase
        let ids = records.map {
            CKRecord.ID(recordName: $0.recordName,
                        zoneID: CKRecordZone.ID(zoneName: $0.zoneName,
                                                ownerName: $0.zoneOwnerName))
        }
        do {
            // `desiredKeys: []` asks only whether the record is there. Nothing
            // about its contents is fetched, let alone logged.
            let results = try await database.records(for: ids, desiredKeys: [])
            return results.values.allSatisfy { result in
                guard case .failure(let error) = result else { return false }
                return (error as? CKError)?.code == .unknownItem
            }
        } catch let error as CKError where Self.meansZoneIsGone(error) {
            // The whole zone is gone, so every record in it is.
            return true
        }
    }

    /// The two codes that mean the zone is not there any more, which is not a
    /// failure for a purge whose whole purpose was to remove it.
    static func meansZoneIsGone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private func record(_ householdID: UUID, in store: NSPersistentStore) throws
    -> HouseholdRecord? {
        let request = HouseholdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
        request.affectedStores = [store]
        request.fetchLimit = 1
        return try persistence.viewContext.fetch(request).first
    }

    /// The Household's record, refused unless it is in this account's private
    /// store — sharing is an owner action, and a received Household's share
    /// belongs to somebody else.
    private func ownedRecord(_ householdID: UUID) throws -> HouseholdRecord {
        let context = persistence.viewContext
        let request = HouseholdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
        request.affectedStores = [persistence.privateStore]
        request.fetchLimit = 1
        guard let record = try context.fetch(request).first else {
            // Either it is gone, or it is a received Household — both mean this
            // account cannot create or update its share.
            throw HouseholdActionFailure(reason: .notOwner,
                                         message: "Only the person who started this fridge can share it.",
                                         diagnosticID: "share.owner")
        }
        return record
    }
}

/// The CloudKit identifiers this build uses. Kept in one place so the container
/// name cannot drift between the stores, the sharing service, and invitation
/// validation.
enum TridgeCloudKit {
    static let containerIdentifier = "iCloud.com.tridge.app"
}
