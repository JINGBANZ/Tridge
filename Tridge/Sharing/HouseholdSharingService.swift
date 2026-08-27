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
    /// The Household's current share, refreshed from the container. Nil when it
    /// has never been shared. Share metadata does not appear in persistent
    /// history, so this is a deliberate refetch rather than an observation.
    func currentShare(for householdID: UUID) async throws -> CKShare?

    /// Creates the Household's share if it has none, then makes sure the saved
    /// share title matches `title` before returning it.
    ///
    /// The title write has to succeed: a reused invitation must never knowingly
    /// display a stale fridge name.
    func prepareShare(for householdID: UUID, title: String) async throws -> HouseholdShareItem

    /// Accepts one invitation into this account's shared store.
    func accept(_ metadata: any ShareInvitationMetadata) async throws
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
