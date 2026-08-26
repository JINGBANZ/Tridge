import CoreData

/// Persists the permanent exact-name links two peers can create independently.
///
/// It never transfers a stock operation, rewrites an item relationship, or
/// deletes a physical root. Convergence is expressed purely as an add-only
/// claim, so an operation an offline member later writes to *either* original
/// root still counts toward the one logical row (ADR 0006).
///
/// It is internal maintenance, not a user command: it runs after every local
/// Inventory save and, later, after every relevant remote-history import.
final class DuplicateReconciler {
    private let persistence: PersistenceController
    private let capabilities: any StoreCapabilityChecking

    init(persistence: PersistenceController,
         capabilities: (any StoreCapabilityChecking)? = nil) {
        self.persistence = persistence
        self.capabilities = capabilities ?? persistence.container
    }

    /// Writes every missing claim for one Household in one transaction, and
    /// returns how many this pass added.
    ///
    /// The projector has already applied the same union in memory, so nothing
    /// user-visible changes here — this is only what makes the link durable and
    /// exportable. A concurrent peer inserting the same endpoints is harmless:
    /// duplicate claims have the same union effect, which is what lets this
    /// stay idempotent without a CloudKit-incompatible uniqueness constraint.
    @discardableResult
    func reconcile(householdID: UUID, today: InventoryDay) async throws -> Int {
        let context = persistence.newReconcilerContext()
        let capabilities = self.capabilities

        return try await context.perform {
            let (household, store) = try self.persistence.resolveHousehold(householdID,
                                                                          in: context)
            guard capabilities.canModifyManagedObjects(in: store) else {
                // Nothing to report: a received Household this account may not
                // write to still projects correctly from the in-memory union.
                return 0
            }

            let projection = HouseholdProjector.project(household, today: today)
            guard !projection.inferredClaims.isEmpty else { return 0 }

            let existing = Set(household.itemMerges.compactMap { try? $0.claim().claim })
            var inserted: [NSManagedObject] = []
            for claim in projection.inferredClaims where !existing.contains(claim) {
                // Refetched immediately before the save: the endpoints must
                // still be this Household's, and their immutable names must
                // still match, or the claim would join two different items.
                guard let left = try Self.root(claim.leftItemID, of: household, store: store,
                                               in: context),
                      let right = try Self.root(claim.rightItemID, of: household, store: store,
                                                in: context),
                      let name = left.normalizedName, !name.isEmpty,
                      name == right.normalizedName
                else { continue }

                inserted.append(Self.insert(claim, into: household, in: context))
            }
            guard !inserted.isEmpty else { return 0 }

            try StoreRouting.assign(inserted, to: store, in: context)
            try StoreRouting.validate(inserted + [household as NSManagedObject], belongTo: store)
            do {
                try context.save()
            } catch {
                throw InventoryRepositoryError.saveFailed(
                    diagnosticID: "reconcile.save.\(Self.errorCode(error))")
            }
            return inserted.count
        }
    }

    private static func insert(_ claim: ItemMergeClaim, into household: HouseholdRecord,
                               in context: NSManagedObjectContext) -> ItemMergeRecord {
        let record = ItemMergeRecord(context: context)
        record.id = UUID()
        record.leftItemID = claim.leftItemID
        record.rightItemID = claim.rightItemID
        record.createdAt = Date()
        record.household = household
        return record
    }

    private static func root(_ id: UUID, of household: HouseholdRecord,
                             store: NSPersistentStore,
                             in context: NSManagedObjectContext) throws -> FridgeItemRecord? {
        let request = FridgeItemRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND household == %@",
                                        id as NSUUID, household)
        request.affectedStores = [store]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func errorCode(_ error: Error) -> String {
        let details = error as NSError
        return "\(details.domain).\(details.code)"
    }
}
