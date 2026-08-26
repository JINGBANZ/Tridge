import CoreData

extension PersistenceController {
    /// The migration could not be written. Retryable, and the id is
    /// content-free — a stage and an error code, never a name or a path.
    struct LegacyImportError: Error, Equatable {
        let diagnosticID: String
    }

    /// Writes every planned legacy purchase into one owned Household's private
    /// graph, in a single transaction, exactly once.
    ///
    /// Each row becomes a fresh purchase root carrying the Household's current
    /// causal frontier plus one `acquired` operation for its quantity — the same
    /// shape an ordinary purchase produces, so nothing downstream has to know
    /// these rows arrived from an archive. The rows keep the legacy ids, which
    /// is what makes a retry recognize what it already wrote: an identical
    /// acquisition means that row succeeded, and a conflicting payload is an
    /// integrity error rather than a second copy.
    ///
    /// Returns the number of rows this attempt actually inserted.
    func importLegacyInventory(_ drafts: [PurchaseDraft],
                               into householdID: UUID) async throws -> Int {
        guard !drafts.isEmpty else { return 0 }
        let context = newWriterContext()

        let inserted = try await context.perform {
            let household = try Self.privateHousehold(householdID, in: context,
                                                      store: self.privateStore)
            guard let contextRaw = InventoryEpochCodec.encode(try household.inventoryFrontier())
            else { throw LegacyImportError(diagnosticID: "legacy.frontier") }

            let existing = try Self.existingRoots(for: drafts, of: household, in: context,
                                                  store: self.privateStore)
            var written: [NSManagedObject] = []
            for draft in drafts {
                guard try Self.needsWriting(draft, existing: existing) else { continue }
                written.append(contentsOf: Self.insert(draft, into: household,
                                                       inventoryEpochContextRaw: contextRaw,
                                                       in: context))
            }
            guard !written.isEmpty else { return 0 }

            try StoreRouting.assign(written, to: self.privateStore, in: context)
            try StoreRouting.validate(written + [household as NSManagedObject],
                                      belongTo: self.privateStore)
            do {
                try context.save()
            } catch {
                throw LegacyImportError(diagnosticID: "legacy.save.\(Self.errorCode(error))")
            }
            // Two objects per migrated row.
            return written.count / 2
        }

        try await verifyLegacyInventory(drafts, in: householdID)
        return inserted
    }

    /// Refetches every expected command id through the store before the
    /// migration may be marked complete, so a save that reported success but
    /// left nothing behind cannot retire the archive.
    private func verifyLegacyInventory(_ drafts: [PurchaseDraft], in householdID: UUID) async throws {
        let context = newWriterContext()
        try await context.perform {
            let request = StockChangeRecord.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@ AND item.household.id == %@",
                                            drafts.map(\.stockChangeID) as NSArray,
                                            householdID as NSUUID)
            request.affectedStores = [self.privateStore]
            guard try context.count(for: request) == drafts.count else {
                throw LegacyImportError(diagnosticID: "legacy.verify")
            }
        }
    }

    private static func privateHousehold(_ id: UUID, in context: NSManagedObjectContext,
                                         store: NSPersistentStore) throws -> HouseholdRecord {
        let request = HouseholdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.affectedStores = [store]
        request.fetchLimit = 1
        guard let household = try context.fetch(request).first else {
            // The destination went away between selection and this write — a
            // deleted or revoked Household, so the archive stays untouched.
            throw LegacyImportError(diagnosticID: "legacy.destination")
        }
        return household
    }

    /// The roots this Household already carries under the migration's ids.
    private static func existingRoots(for drafts: [PurchaseDraft], of household: HouseholdRecord,
                                      in context: NSManagedObjectContext,
                                      store: NSPersistentStore) throws -> [UUID: FridgeItemRecord] {
        let request = FridgeItemRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@ AND household == %@",
                                        drafts.map(\.itemID) as NSArray, household)
        request.affectedStores = [store]
        return try context.fetch(request).reduce(into: [:]) { found, record in
            if let id = record.id { found[id] = record }
        }
    }

    /// Whether this row still has to be written, or throws when what is already
    /// there is not what this row would have written.
    private static func needsWriting(_ draft: PurchaseDraft,
                                     existing: [UUID: FridgeItemRecord]) throws -> Bool {
        guard let root = existing[draft.itemID] else { return true }
        let acquisition = root.stockChanges.first { $0.id == draft.stockChangeID }
        guard let acquisition, acquisition.delta == draft.quantity,
              acquisition.reasonRaw == StockReason.acquired.rawValue,
              root.normalizedName == draft.normalizedName
        else { throw LegacyImportError(diagnosticID: "legacy.conflict") }
        return false
    }

    /// One purchase root and its acquisition, in insertion order.
    private static func insert(_ draft: PurchaseDraft, into household: HouseholdRecord,
                               inventoryEpochContextRaw: String,
                               in context: NSManagedObjectContext) -> [NSManagedObject] {
        let root = FridgeItemRecord(context: context)
        root.id = draft.itemID
        root.name = draft.name
        root.normalizedName = draft.normalizedName
        root.inventoryEpochContextRaw = inventoryEpochContextRaw
        root.artKey = draft.artKey
        root.storageRaw = draft.storage.rawValue
        root.purchaseDay = draft.purchaseDay.ordinal
        root.expiryDay = draft.expiryDay.ordinal
        root.expirySourceRaw = draft.expirySource.rawValue
        // The purchase instant, not `Date()`: a retry must be able to produce
        // the same row, and the archive is the only authority on when this was
        // bought.
        root.createdAt = draft.occurredAt
        root.modifiedAt = draft.occurredAt
        root.household = household

        let event = draft.acquisition
        let acquisition = StockChangeRecord(context: context)
        acquisition.id = event.id
        acquisition.delta = event.delta
        acquisition.reasonRaw = event.reason.rawValue
        acquisition.occurredAt = event.occurredAt
        acquisition.item = root

        return [root, acquisition]
    }

    private static func errorCode(_ error: Error) -> String {
        let details = error as NSError
        return "\(details.domain).\(details.code)"
    }
}
