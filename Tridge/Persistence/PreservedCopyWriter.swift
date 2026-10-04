import CoreData

extension CoreDataInventoryRepository {
    /// Copies the Household's currently visible inventory into a fresh unshared
    /// private Household.
    ///
    /// This is what "Stop Sharing & Keep My Fridge" actually preserves: the
    /// owner's *local projection*, not any peer's unexported work — CloudKit
    /// offers no acknowledgement that every member has uploaded, so the promise
    /// is deliberately the smaller one the app can keep.
    ///
    /// One transaction: the new Household, one fresh root per active logical
    /// group carrying that group's canonical metadata, and one `preserved`
    /// operation equal to its aggregate projected quantity. Physical aliases,
    /// merge claims, clear epochs, deleted and zero groups, and old operation
    /// history are deliberately *not* copied — the copy is a starting state,
    /// not a second history that could resurrect what the owner had closed.
    ///
    /// A retry finds the preallocated destination already present and does
    /// nothing, so the copy exists exactly once however many times this runs.
    /// Returns how many logical groups the copy holds.
    @discardableResult
    func copyActiveInventory(from sourceID: UUID, into destinationID: UUID, named name: String,
                             today: InventoryDay, now: Date = Date()) async throws -> Int {
        try await write(to: sourceID) { scope in
            let privateStore = scope.persistence.store(for: .privateDatabase)
            if let existing = try Self.household(destinationID, in: privateStore,
                                                 context: scope.context) {
                // Already copied. Counting what is there keeps the caller's
                // verification meaningful on a resume.
                return existing.items.count
            }

            let projection = scope.project(today: today)
            let destination = HouseholdRecord(context: scope.context)
            let epochID = UUID()
            destination.id = destinationID
            destination.name = name
            destination.initialInventoryEpochID = epochID
            destination.createdAt = now
            destination.modifiedAt = now
            guard let contextRaw = InventoryEpochCodec.encode([epochID]) else {
                throw InventoryRepositoryError.unreadableFrontier
            }

            var inserted: [NSManagedObject] = [destination]
            for item in projection.items {
                let root = FridgeItemRecord(context: scope.context)
                root.id = UUID()
                root.name = item.name
                root.normalizedName = item.normalizedName
                root.inventoryEpochContextRaw = contextRaw
                root.artKey = item.artKey
                root.storageRaw = item.storage.rawValue
                root.purchaseDay = item.purchaseDay.ordinal
                root.expiryDay = item.expiryDay.ordinal
                root.expirySourceRaw = item.expirySource.rawValue
                root.createdAt = now
                root.modifiedAt = now
                root.household = destination

                let preserved = StockChangeRecord(context: scope.context)
                preserved.id = UUID()
                preserved.delta = item.quantity
                preserved.reasonRaw = StockReason.preserved.rawValue
                preserved.occurredAt = now
                preserved.item = root

                inserted.append(contentsOf: [root, preserved])
            }

            // Routed to the private store explicitly: the source lives in the
            // shared store, and Core Data must not be left to pick a default.
            try StoreRouting.assign(inserted, to: privateStore, in: scope.context)
            try StoreRouting.validate(inserted, belongTo: privateStore)
            do {
                try scope.context.save()
            } catch {
                let details = error as NSError
                throw InventoryRepositoryError.saveFailed(
                    diagnosticID: "preserve.save.\(details.domain).\(details.code)")
            }
            return projection.items.count
        }
    }

    /// Refetches the copy through the store and returns its logical rows, so a
    /// save that reported success but left nothing behind cannot lead to a
    /// purge.
    func verifyPreservedCopy(_ destinationID: UUID,
                             today: InventoryDay) async throws -> HouseholdProjection {
        try await projection(of: destinationID, today: today)
    }

    static func household(_ id: UUID, in store: NSPersistentStore,
                          context: NSManagedObjectContext) throws -> HouseholdRecord? {
        let request = HouseholdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.affectedStores = [store]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}
