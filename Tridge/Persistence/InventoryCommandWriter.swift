import CoreData

/// The Inventory commands that operate on inventory a Household already has:
/// metadata edits, quantity adjustment, eat, toss, delete, Clear All, and
/// Household rename.
///
/// Purchases live in `CoreDataInventoryRepository` itself because they are the
/// only commands that create a physical root. Everything here resolves the
/// current permanent component inside its own writer transaction and appends to
/// it — no record is ever edited in place except the canonical member's
/// metadata, and no stock operation is ever rewritten or removed.
extension CoreDataInventoryRepository {
    // MARK: - Metadata and quantity

    /// Commits one Item Detail draft.
    ///
    /// Quantity becomes an immutable `adjusted` operation measured against the
    /// projection the editor could actually see, so remote operations it never
    /// saw still compose. Art, storage, and expiry land on the group's canonical
    /// member — its lowest-id physical root — which is the rule that keeps two
    /// peers editing the same logical item from writing to different rows.
    func updateItem(_ command: UpdateItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection {
        try command.validate()
        return try await write(to: command.householdID) { scope in
            let projection = scope.project(today: today)
            // A stale sheet whose group is no longer active is refused rather
            // than reviving a closed batch; the UI offers Add as New.
            guard let item = projection.item(addressing: command.itemID) else {
                throw InventoryRepositoryError.itemUnavailable
            }
            // The canonical member is the lowest-id member, which is also the
            // one every stock-only command appends to.
            guard let canonical = try HouseholdFetch.item(item.id, in: scope) else {
                throw InventoryRepositoryError.itemUnavailable
            }

            var inserted: [NSManagedObject] = []
            if command.needsStockEvent {
                // The retry check comes first: on a replay the earlier
                // adjustment is already in the projection, so recomputing the
                // delta would produce a second, different operation under one
                // command id.
                let state = try HouseholdFetch.retryState(command.stockChangeID,
                                                          expecting: .adjusted, delta: nil,
                                                          occurredAt: command.occurredAt,
                                                          in: scope)
                if state == .absent,
                   let event = command.adjustment(fromLocalProjection: item.quantity) {
                    inserted.append(InventoryCommandWriter.insert(event, on: canonical,
                                                                  in: scope.context))
                }
            }

            let edited = try InventoryCommandWriter.applyMetadata(command, to: canonical,
                                                                  scope: scope)
            guard !inserted.isEmpty || edited else {
                // Nothing left to write: an identical replay, or a draft whose
                // quantity already matches.
                return projection
            }
            try scope.save(inserted, stage: "update")
            return scope.project(today: today)
        }
    }

    // MARK: - Eat and toss

    /// Appends one `-1` operation to the group's lowest-id member. Nothing is
    /// decremented in place, so two members consuming concurrently both count.
    func consumeItem(_ command: ConsumeItemCommand,
                     today: InventoryDay) async throws -> HouseholdProjection {
        try await write(to: command.householdID) { scope in
            let projection = scope.project(today: today)
            guard let item = projection.item(addressing: command.itemID) else {
                throw InventoryRepositoryError.itemUnavailable
            }
            let event = command.event
            let state = try HouseholdFetch.retryState(command.stockChangeID,
                                                      expecting: event.reason, delta: event.delta,
                                                      occurredAt: event.occurredAt, in: scope)
            guard state == .absent else { return projection }

            guard let member = try HouseholdFetch.item(item.id, in: scope) else {
                throw InventoryRepositoryError.itemUnavailable
            }
            try scope.save([InventoryCommandWriter.insert(event, on: member, in: scope.context)],
                           stage: "consume")
            return scope.project(today: today)
        }
    }

    // MARK: - Delete

    /// Closes one logical item by fanning a single terminal marker out to every
    /// physical member currently linked to it.
    ///
    /// The grouped reducer counts that id once, so the fan-out changes nothing
    /// about the projected quantity — what it buys is that a member which
    /// imports later, and links to this component, cannot expose stock the user
    /// already deleted. A retry fills whichever markers are missing and treats
    /// identical existing ones as success; finding the id on only some members
    /// never completes it.
    func deleteItem(_ command: DeleteItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection {
        try await write(to: command.householdID) { scope in
            // Resolved through the components rather than the visible rows: a
            // retry has to find the group it already terminated, and a
            // terminated group is by definition absent from Home.
            guard let group = scope.project(today: today).group(addressing: command.itemID) else {
                throw InventoryRepositoryError.itemUnavailable
            }

            let marker = command.marker
            var carrying: Set<UUID> = []
            for record in try HouseholdFetch.stockChanges(command.stockChangeID, in: scope) {
                guard record.delta == marker.delta,
                      record.reasonRaw == marker.reason.rawValue,
                      record.occurredAt == marker.occurredAt,
                      let ownerID = record.item?.id
                else { throw InventoryRepositoryError.conflictingRetry(command.stockChangeID) }
                carrying.insert(ownerID)
            }

            let missing = group.memberIDs.filter { !carrying.contains($0) }
            guard !missing.isEmpty else { return scope.project(today: today) }

            var inserted: [NSManagedObject] = []
            for id in missing {
                guard let member = try HouseholdFetch.item(id, in: scope) else {
                    throw InventoryRepositoryError.itemUnavailable
                }
                inserted.append(InventoryCommandWriter.insert(marker, on: member,
                                                              in: scope.context))
            }
            try scope.save(inserted, stage: "delete")
            return scope.project(today: today)
        }
    }

    // MARK: - Clear All

    /// Advances the Household's causal frontier by one leaf and writes nothing
    /// else (ADR 0009).
    ///
    /// A retry replays the record it already wrote rather than rebuilding one:
    /// by then the frontier has moved, so a rebuilt record would carry the same
    /// id with different parents, and two conflicting copies of one clear would
    /// drop both — leaving the frontier unmoved while the UI reported success.
    func clearActiveHousehold(_ command: ClearHouseholdCommand,
                              today: InventoryDay) async throws -> HouseholdProjection {
        try await write(to: command.householdID) { scope in
            if let existing = try HouseholdFetch.clearRecord(command.clearRecordID, in: scope) {
                guard existing.epochID == command.epochID,
                      existing.occurredAt == command.occurredAt
                else { throw InventoryRepositoryError.conflictingRetry(command.clearRecordID) }
                return scope.project(today: today)
            }

            guard let reduction = try? scope.household.epochReduction(),
                  let event = command.clearRecord(from: reduction),
                  let parentsRaw = InventoryEpochCodec.encode(event.parentEpochIDs)
            else { throw InventoryRepositoryError.unreadableFrontier }

            let record = HouseholdClearRecord(context: scope.context)
            record.id = event.id
            record.epochID = event.epochID
            record.parentEpochIDsRaw = parentsRaw
            record.revision = event.revision
            record.occurredAt = event.occurredAt
            record.household = scope.household

            try scope.save([record], stage: "clear")
            return scope.project(today: today)
        }
    }

    // MARK: - Household rename

    /// Renames an owned Household. A received one is refused: its name belongs
    /// to the owner's record, and the share title follows it from there.
    func renameOwnedHousehold(_ command: RenameHouseholdCommand) async throws -> HouseholdSnapshot {
        try command.validate()
        return try await write(to: command.householdID) { scope in
            guard scope.ownership == .owned else {
                throw InventoryRepositoryError.householdNotOwned
            }
            guard scope.canUpdate(scope.household) else {
                throw InventoryRepositoryError.permissionDenied
            }
            let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if scope.household.name != name {
                scope.household.name = name
                scope.household.modifiedAt = Date()
                try scope.save([], stage: "rename")
            }
            // Returned rather than re-read: the view context merges a writer's
            // save asynchronously, so a fetch here could still see the old name.
            // Share status is refreshed separately and overlaid by the caller.
            return try scope.household.snapshot(ownership: .owned, isShared: false)
        }
    }
}

/// The record-level pieces every command above shares.
enum InventoryCommandWriter {
    /// One immutable stock operation, attached to one physical member.
    static func insert(_ event: StockEvent, on item: FridgeItemRecord,
                       in context: NSManagedObjectContext) -> StockChangeRecord {
        let record = StockChangeRecord(context: context)
        record.id = event.id
        record.delta = event.delta
        record.reasonRaw = event.reason.rawValue
        record.occurredAt = event.occurredAt
        record.item = item
        return record
    }

    /// Applies the draft's art, storage, and expiry to the canonical member,
    /// and reports whether anything actually changed.
    ///
    /// The capability check comes after the comparison and before the first
    /// mutation: updating an already-exported record is a different CloudKit
    /// permission from inserting into the zone, and a draft that changes
    /// nothing should not be refused for a permission it never needed.
    ///
    /// `modifiedAt` moves only for a real metadata change: a stock-only command
    /// must leave it alone, or every eat would look like an edit to the peer
    /// merging the two records.
    static func applyMetadata(_ command: UpdateItemCommand, to canonical: FridgeItemRecord,
                              scope: CoreDataInventoryRepository.CommandContext) throws -> Bool {
        let art = command.artKey.flatMap { $0 == canonical.artKey ? nil : $0 }
        let storage = command.storage.flatMap { $0.rawValue == canonical.storageRaw ? nil : $0 }
        let expiry = command.expiryDay.flatMap { $0.ordinal == canonical.expiryDay ? nil : $0 }
        guard art != nil || storage != nil || expiry != nil else { return false }

        guard scope.canUpdate(canonical) else {
            throw InventoryRepositoryError.permissionDenied
        }
        if let art { canonical.artKey = art }
        if let storage { canonical.storageRaw = storage.rawValue }
        if let expiry {
            canonical.expiryDay = expiry.ordinal
            // A date the user chose is never overwritten by a later model guess.
            canonical.expirySourceRaw = ExpirySource.userSet.rawValue
        }
        canonical.modifiedAt = command.occurredAt
        return true
    }
}

/// Fetches confined to one Household and one store. Every command resolves what
/// it addresses through these, so nothing can reach a record in the other store
/// or in another Household.
enum HouseholdFetch {
    /// Whether the operation a command id names is already stored.
    enum RetryState: Equatable {
        case absent
        /// The identical operation is already there; this command already ran.
        case alreadyApplied
    }

    static func item(_ id: UUID, in scope: CoreDataInventoryRepository.CommandContext) throws
    -> FridgeItemRecord? {
        let request = FridgeItemRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND household == %@",
                                        id as NSUUID, scope.household)
        request.affectedStores = [scope.store]
        request.fetchLimit = 1
        return try scope.context.fetch(request).first
    }

    /// Every stock operation stored under one command id in this Household.
    /// More than one is normal only for Delete, whose marker fans out.
    static func stockChanges(_ commandID: UUID,
                             in scope: CoreDataInventoryRepository.CommandContext) throws
    -> [StockChangeRecord] {
        let request = StockChangeRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND item.household == %@",
                                        commandID as NSUUID, scope.household)
        request.affectedStores = [scope.store]
        return try scope.context.fetch(request)
    }

    /// Whether a singular command still has to write its operation.
    ///
    /// `delta` is nil for a quantity adjustment, whose value depends on the
    /// projection the editor saw and therefore cannot be recomputed on a
    /// replay; the command id, reason, and instant identify it instead.
    static func retryState(_ commandID: UUID, expecting reason: StockReason, delta: Int64?,
                           occurredAt: Date,
                           in scope: CoreDataInventoryRepository.CommandContext) throws
    -> RetryState {
        let existing = try stockChanges(commandID, in: scope)
        guard let record = existing.first else { return .absent }
        guard existing.count == 1, record.reasonRaw == reason.rawValue,
              record.occurredAt == occurredAt, delta.map({ record.delta == $0 }) ?? true
        else { throw InventoryRepositoryError.conflictingRetry(commandID) }
        return .alreadyApplied
    }

    static func clearRecord(_ commandID: UUID,
                            in scope: CoreDataInventoryRepository.CommandContext) throws
    -> HouseholdClearRecord? {
        let request = HouseholdClearRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND household == %@",
                                        commandID as NSUUID, scope.household)
        request.affectedStores = [scope.store]
        request.fetchLimit = 1
        return try scope.context.fetch(request).first
    }
}
