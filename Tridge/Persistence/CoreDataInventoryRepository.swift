import CoreData

/// Why a command could not be applied. Every case is content-free: a category
/// and, at most, an opaque id — never a household name, an item name, or a
/// quantity (wiki/household-sharing.md → "Privacy and security").
enum InventoryRepositoryError: Error, Equatable {
    /// The Household is not in either of this account's stores any more: it was
    /// deleted, left, revoked, or never imported. The command wrote nothing.
    case householdUnavailable
    /// CloudKit does not currently permit this account to write here. Checked
    /// immediately before mutation; CloudKit remains the authority.
    case permissionDenied
    /// A retry found a different payload under a command id it had already
    /// written. Neither copy can be trusted, so the whole command fails.
    case conflictingRetry(UUID)
    /// The Household's causal frontier could not be read, so no purchase root
    /// could be stamped with a context a concurrent Clear All could judge.
    case unreadableFrontier
    case saveFailed(diagnosticID: String)
}

/// Whether CloudKit currently permits a write, checked immediately before one.
/// A protocol so tests can deny without a live share; CloudKit itself remains
/// the authority, and these checks only improve the error the UI shows.
protocol StoreCapabilityChecking {
    func canModifyManagedObjects(in store: NSPersistentStore) -> Bool
    func canUpdateRecord(forManagedObjectWith objectID: NSManagedObjectID) -> Bool
}

/// The production answer: the container's own view of the current share.
struct CloudKitStoreCapabilities: StoreCapabilityChecking {
    let container: NSPersistentCloudKitContainer

    func canModifyManagedObjects(in store: NSPersistentStore) -> Bool {
        container.canModifyManagedObjects(in: store)
    }

    func canUpdateRecord(forManagedObjectWith objectID: NSManagedObjectID) -> Bool {
        container.canUpdateRecord(forManagedObjectWith: objectID)
    }
}

/// Async Household queries and Inventory commands. No CloudKit presentation and
/// no SwiftUI: every value that crosses this boundary is an immutable snapshot.
protocol InventoryRepository {
    /// The Household's current logical projection.
    func projection(of householdID: UUID, today: InventoryDay) async throws -> HouseholdProjection

    /// Confirms one hand-typed purchase.
    func addManualItem(_ command: AddManualItemCommand,
                       today: InventoryDay) async throws -> HouseholdProjection

    /// Confirms a whole reviewed receipt. The rows save atomically, so a crash
    /// cannot leave half a receipt in the fridge.
    func addReviewedRows(_ command: AddReviewedRowsCommand,
                         today: InventoryDay) async throws -> HouseholdProjection
}

/// The Core Data implementation: resolve the Household's store, check
/// capability immediately before mutating, assign every inserted record to that
/// store, save once, and return snapshots.
final class CoreDataInventoryRepository: InventoryRepository {
    private let persistence: PersistenceController
    private let capabilities: any StoreCapabilityChecking
    /// Commands write one at a time — see `CommandTransactions`.
    private let transactions = CommandTransactions()

    init(persistence: PersistenceController,
         capabilities: (any StoreCapabilityChecking)? = nil) {
        self.persistence = persistence
        self.capabilities = capabilities
            ?? CloudKitStoreCapabilities(container: persistence.container)
    }

    // MARK: - Queries

    /// Read through a fresh context rather than the view context, so a
    /// projection taken right after a command can never be a runloop turn
    /// behind the save the user just made.
    func projection(of householdID: UUID,
                    today: InventoryDay) async throws -> HouseholdProjection {
        let context = persistence.newReaderContext()
        return try await context.perform {
            let household = try self.persistence.resolveHousehold(householdID,
                                                                 in: context).household
            return HouseholdProjector.project(household, today: today)
        }
    }

    // MARK: - Purchases

    func addManualItem(_ command: AddManualItemCommand,
                       today: InventoryDay) async throws -> HouseholdProjection {
        try command.validate()
        return try await savePurchases([command.draft], into: command.householdID, today: today)
    }

    func addReviewedRows(_ command: AddReviewedRowsCommand,
                         today: InventoryDay) async throws -> HouseholdProjection {
        try command.validate()
        return try await savePurchases(command.rows, into: command.householdID, today: today)
    }

    /// Every purchase — one hand-typed item or a whole receipt — takes this
    /// path, because they differ only in how many rows they carry.
    ///
    /// One `perform`, one save: the fresh frontier-stamped roots, their
    /// `acquired` operations, and the metadata edits that land on the resulting
    /// canonical members are all-or-nothing. The transaction also runs alone,
    /// because `needsWriting`'s check and the insert it authorizes are only
    /// atomic within one context.
    private func savePurchases(_ rows: [PurchaseDraft], into householdID: UUID,
                               today: InventoryDay) async throws -> HouseholdProjection {
        let persistence = self.persistence
        let capabilities = self.capabilities

        return try await transactions.run {
            // Opened inside the serialized transaction, so its very first fetch
            // already sees whatever the command before it saved.
            let context = persistence.newWriterContext()
            return try await context.perform {
                let (household, store) = try persistence.resolveHousehold(householdID,
                                                                         in: context)
                // Immediately before mutation, per the sharing contract: a stale
                // capability answer would let the UI report a save CloudKit will
                // reject.
                guard capabilities.canModifyManagedObjects(in: store) else {
                    throw InventoryRepositoryError.permissionDenied
                }
                guard let frontier = try? household.inventoryFrontier(),
                      let contextRaw = InventoryEpochCodec.encode(frontier)
                else {
                    throw InventoryRepositoryError.unreadableFrontier
                }

                // Planned against what the Household projects *now*, so a same-name
                // purchase copies the established metadata instead of restamping a
                // scan guess over it (ADR 0011). Planning also refuses a row that
                // would push its group past the representable total, before any
                // record is inserted.
                let plans = try PurchasePlanner.plan(
                    rows: rows,
                    in: HouseholdProjector.project(household, today: today).items,
                    today: today)

                var inserted: [NSManagedObject] = []
                var written: [(draft: PurchaseDraft, plan: PurchasePlan)] = []
                for (draft, plan) in zip(rows, plans) {
                    guard try Self.needsWriting(draft, in: household, store: store,
                                                context: context)
                    else { continue }
                    inserted.append(contentsOf: Self.insert(draft, metadata: plan.rootMetadata,
                                                            into: household,
                                                            inventoryEpochContextRaw: contextRaw,
                                                            in: context))
                    written.append((draft, plan))
                }
                guard !inserted.isEmpty else {
                    // Every row of this command already landed: an identical retry
                    // is a no-op, not a second purchase.
                    return HouseholdProjector.project(household, today: today)
                }

                try StoreRouting.assign(inserted, to: store, in: context)
                try StoreRouting.validate(inserted + [household as NSManagedObject],
                                          belongTo: store)

                // The canonical member is only knowable once the new roots exist and
                // the projector has linked them, so deliberate edits are applied
                // after insertion and still inside this one transaction.
                let projection = HouseholdProjector.project(household, today: today)
                try Self.applyCanonicalEdits(written, in: projection, of: household,
                                             capabilities: capabilities)

                do {
                    try context.save()
                } catch {
                    throw InventoryRepositoryError.saveFailed(
                        diagnosticID: "purchase.save.\(Self.errorCode(error))")
                }
                return HouseholdProjector.project(household, today: today)
            }
        }
    }

    // MARK: - Writing one purchase

    /// Whether this row still has to be written, or throws when what is already
    /// stored under its command id is not what it would have written.
    private static func needsWriting(_ draft: PurchaseDraft, in household: HouseholdRecord,
                                     store: NSPersistentStore,
                                     context: NSManagedObjectContext) throws -> Bool {
        let request = StockChangeRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND item.household == %@",
                                        draft.stockChangeID as NSUUID, household)
        request.affectedStores = [store]
        request.fetchLimit = 1
        guard let existing = try context.fetch(request).first else { return true }

        let acquisition = draft.acquisition
        // The instant is part of the immutable event payload — it is what the
        // reducer's corrupt-id tie-break sorts on, and what the root's
        // `createdAt` was stamped from — so a retry carrying a different one is
        // a conflicting command, not the same one.
        guard existing.delta == acquisition.delta,
              existing.reasonRaw == acquisition.reason.rawValue,
              existing.occurredAt == acquisition.occurredAt,
              existing.item?.id == draft.itemID,
              existing.item?.normalizedName == draft.normalizedName
        else { throw InventoryRepositoryError.conflictingRetry(draft.stockChangeID) }
        return false
    }

    /// One fresh purchase root and its single `acquired` operation, in insertion
    /// order. Every purchase gets its own root — including a same-name one — so
    /// the new stock has causal context of its own (ADR 0008).
    private static func insert(_ draft: PurchaseDraft, metadata: PurchaseRootMetadata,
                               into household: HouseholdRecord,
                               inventoryEpochContextRaw: String,
                               in context: NSManagedObjectContext) -> [NSManagedObject] {
        let root = FridgeItemRecord(context: context)
        root.id = draft.itemID
        root.name = metadata.name
        root.normalizedName = NameKey.normalize(metadata.name)
        root.inventoryEpochContextRaw = inventoryEpochContextRaw
        root.artKey = metadata.artKey
        root.storageRaw = metadata.storage.rawValue
        root.purchaseDay = metadata.purchaseDay.ordinal
        root.expiryDay = metadata.expiryDay.ordinal
        root.expirySourceRaw = metadata.expirySource.rawValue
        // The command's own instant rather than `Date()`: a retry has to be able
        // to produce the identical row.
        root.createdAt = draft.occurredAt
        root.modifiedAt = draft.occurredAt
        root.household = household

        let acquisition = StockChangeRecord(context: context)
        let event = draft.acquisition
        acquisition.id = event.id
        acquisition.delta = event.delta
        acquisition.reasonRaw = event.reason.rawValue
        acquisition.occurredAt = event.occurredAt
        acquisition.item = root

        return [root, acquisition]
    }

    /// Applies the fields the user deliberately changed to the canonical member
    /// of the group each new root landed in.
    ///
    /// Untouched scan guesses, inferred art, and form defaults are absent from
    /// `explicitMetadataFields`, so they cannot overwrite metadata an existing
    /// item already established (ADR 0011).
    private static func applyCanonicalEdits(
        _ written: [(draft: PurchaseDraft, plan: PurchasePlan)],
        in projection: HouseholdProjection, of household: HouseholdRecord,
        capabilities: any StoreCapabilityChecking
    ) throws {
        let roots = Dictionary(household.items.compactMap { record -> (UUID, FridgeItemRecord)? in
            record.id.map { ($0, record) }
        }, uniquingKeysWith: { first, _ in first })
        // A closure rather than a key path: Swift key paths cannot address
        // tuple elements.
        let insertedIDs = Set(written.map { $0.draft.itemID })

        for (draft, plan) in written {
            guard let edit = plan.canonicalEdit,
                  let group = projection.items.first(where: { $0.memberIDs.contains(draft.itemID) }),
                  let canonical = roots[group.id]
            else { continue }
            // Updating a record that already exists is a different CloudKit
            // permission from inserting into the zone. A root this command just
            // inserted has no record to ask about yet.
            if !insertedIDs.contains(group.id),
               !capabilities.canUpdateRecord(forManagedObjectWith: canonical.objectID) {
                throw InventoryRepositoryError.permissionDenied
            }

            if let artKey = edit.artKey { canonical.artKey = artKey }
            if let storage = edit.storage { canonical.storageRaw = storage.rawValue }
            if let expiryDay = edit.expiryDay {
                canonical.expiryDay = expiryDay.ordinal
                // A date the user chose is never overwritten by a later model
                // guess (spec → "Definition of done").
                canonical.expirySourceRaw = ExpirySource.userSet.rawValue
            }
            canonical.modifiedAt = draft.occurredAt
        }
    }

    private static func errorCode(_ error: Error) -> String {
        let details = error as NSError
        return "\(details.domain).\(details.code)"
    }
}

/// Runs the repository's command transactions one at a time.
///
/// Each command opens its own writer context, and Core Data orders nothing
/// between two of them: a preallocated draft submitted twice — a double-tap on
/// Confirm, or a resume racing the save it was resuming — would let both
/// contexts fetch no existing operation and then insert the same item and
/// StockChange ids. Nothing downstream can undo that. The model carries no
/// uniqueness constraint to catch it at save time, because CloudKit forbids
/// one, and a duplicate physical root is permanent and exportable.
///
/// So the check and the insert it authorizes are made atomic the only way that
/// spans contexts: the next transaction starts after the previous one has
/// saved, which is exactly when its retry check can see that save.
private actor CommandTransactions {
    /// The last transaction admitted, whatever its outcome.
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(
        _ transaction: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            if let previous { await previous.value }
            return try await transaction()
        }
        // The chain records completion only, so a refused command cannot fail
        // the one behind it — and it is set before the first suspension, so two
        // callers cannot chain onto the same predecessor.
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
