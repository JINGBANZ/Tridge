import Foundation

public enum InventoryCommandError: Error, Equatable, Sendable {
    case emptyItemName
    case emptyHouseholdName
    case quantityNotPositive
    case quantityNotANumber
    case quantityOutOfRange
    case noRows
    /// Two rows of one save reused an id that must be unique per inserted object.
    case duplicatePreallocatedID
    case noChanges
}

/// Parses a typed or scanned quantity. Rejecting is deliberate: silently
/// clamping an out-of-range entry would write a number the user never chose.
public enum InventoryQuantity {
    public static func parse(_ text: String) throws -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading minus is parsed only so a negative entry reports "not
        // positive" rather than the vaguer "not a number".
        let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw InventoryCommandError.quantityNotANumber
        }
        guard let value = Int64(trimmed) else { throw InventoryCommandError.quantityOutOfRange }
        guard value > 0 else { throw InventoryCommandError.quantityNotPositive }
        return value
    }
}

/// A metadata field the user changed on purpose. Scan guesses, inferred art, and
/// form defaults never appear here, so an untouched guess cannot overwrite
/// metadata an existing item already established (ADR 0011).
public enum ExplicitMetadataField: String, Hashable, CaseIterable, Sendable {
    case art, storage, expiryDay
}

/// One confirmed purchase — from Review or manual add. Every purchase creates a
/// fresh physical root (ADR 0008), so the ids are preallocated and reused on
/// retry rather than regenerated.
public struct PurchaseDraft: Hashable, Sendable {
    public let itemID: UUID
    public let stockChangeID: UUID
    public let name: String
    public let quantity: Int64
    public let artKey: String
    public let storage: StorageLocation
    public let purchaseDay: InventoryDay
    public let expiryDay: InventoryDay
    public let expirySource: ExpirySource
    public let explicitMetadataFields: Set<ExplicitMetadataField>
    /// Allocated with the command, never recomputed: a retry must produce a
    /// byte-identical event or the repository reads it as a conflicting payload.
    public let occurredAt: Date

    public init(itemID: UUID, stockChangeID: UUID, name: String, quantity: Int64, artKey: String,
                storage: StorageLocation, purchaseDay: InventoryDay, expiryDay: InventoryDay,
                expirySource: ExpirySource, explicitMetadataFields: Set<ExplicitMetadataField>,
                occurredAt: Date = Date()) {
        self.itemID = itemID
        self.stockChangeID = stockChangeID
        self.name = name
        self.quantity = quantity
        self.artKey = artKey
        self.storage = storage
        self.purchaseDay = purchaseDay
        self.expiryDay = expiryDay
        self.expirySource = expirySource
        self.explicitMetadataFields = explicitMetadataFields
        self.occurredAt = occurredAt
    }

    /// Confirms one reviewed receipt row. The row's raw receipt text stays in
    /// the in-memory draft and is dropped here: nothing derived from a receipt
    /// image is ever persisted or synchronized.
    /// The draft starts with no explicit metadata fields: every value here is a
    /// model guess, and only what the user then changes in Review counts as an
    /// edit that may overwrite an existing item's established metadata.
    public init(reviewing parsed: ParsedItem, itemID: UUID, stockChangeID: UUID,
                purchaseDay: InventoryDay, occurredAt: Date = Date()) {
        // `shelf_life_days` is an unbounded integer in the scan API's schema, so
        // a hallucinated value can exceed the supported civil range. Clamping
        // keeps the row usable; falling back to the purchase day would stamp it
        // "expires today" and fire an immediate reminder.
        let shelfLife = min(parsed.shelfLifeDays, InventoryDay.latest.days(since: purchaseDay))
        self.init(itemID: itemID, stockChangeID: stockChangeID, name: parsed.name,
                  quantity: Int64(parsed.quantity), artKey: parsed.id.rawValue,
                  storage: parsed.storage, purchaseDay: purchaseDay,
                  expiryDay: purchaseDay.adding(days: shelfLife) ?? purchaseDay,
                  expirySource: .llmEstimate, explicitMetadataFields: [],
                  occurredAt: occurredAt)
    }

    public var normalizedName: String { NameKey.normalize(name) }

    /// The initial stock of this purchase's fresh root.
    public var acquisition: StockEvent {
        StockEvent(id: stockChangeID, delta: quantity, reason: .acquired, occurredAt: occurredAt)
    }

    func validate() throws {
        guard !normalizedName.isEmpty else { throw InventoryCommandError.emptyItemName }
        guard quantity > 0 else { throw InventoryCommandError.quantityNotPositive }
    }
}

public struct AddManualItemCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let draft: PurchaseDraft

    public init(householdID: UUID, commandID: UUID, draft: PurchaseDraft) {
        self.householdID = householdID
        self.commandID = commandID
        self.draft = draft
    }

    public func validate() throws { try draft.validate() }
}

public struct AddReviewedRowsCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let rows: [PurchaseDraft]

    public init(householdID: UUID, commandID: UUID, rows: [PurchaseDraft]) {
        self.householdID = householdID
        self.commandID = commandID
        self.rows = rows
    }

    /// The whole multirow save is atomic, so its preallocated ids are checked
    /// together: a reused id would make a crash-resume ambiguous.
    public func validate() throws {
        guard !rows.isEmpty else { throw InventoryCommandError.noRows }
        try rows.forEach { try $0.validate() }
        let ids = rows.map(\.itemID) + rows.map(\.stockChangeID)
        guard Set(ids).count == ids.count else {
            throw InventoryCommandError.duplicatePreallocatedID
        }
    }
}

/// Edits one logical item. `itemID` may address the logical id or any physical
/// member; the repository resolves the current component in its writer context.
public struct UpdateItemCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let itemID: UUID
    /// Used only when the quantity field actually moves the projection.
    public let stockChangeID: UUID
    public let targetQuantity: Int64?
    public let artKey: String?
    public let storage: StorageLocation?
    public let expiryDay: InventoryDay?
    public let occurredAt: Date

    public init(householdID: UUID, commandID: UUID, itemID: UUID, stockChangeID: UUID,
                targetQuantity: Int64?, artKey: String?, storage: StorageLocation?,
                expiryDay: InventoryDay?, occurredAt: Date = Date()) {
        self.householdID = householdID
        self.commandID = commandID
        self.itemID = itemID
        self.stockChangeID = stockChangeID
        self.targetQuantity = targetQuantity
        self.artKey = artKey
        self.storage = storage
        self.expiryDay = expiryDay
        self.occurredAt = occurredAt
    }

    /// There is no saved-name update: item names are immutable once saved
    /// (ADR 0005), which is what keeps every exact-name merge permanent.
    public var needsStockEvent: Bool { targetQuantity != nil }

    /// The quantity field commits the difference from what the editor could
    /// see, not the target, so remote operations it never saw still compose.
    public func adjustment(fromLocalProjection projection: Int64) -> StockEvent? {
        guard let targetQuantity, targetQuantity != projection else { return nil }
        return StockEvent(id: stockChangeID, delta: targetQuantity - projection,
                          reason: .adjusted, occurredAt: occurredAt)
    }

    public func validate() throws {
        if let targetQuantity, targetQuantity <= 0 {
            throw InventoryCommandError.quantityNotPositive
        }
        guard targetQuantity != nil || artKey != nil || storage != nil || expiryDay != nil else {
            throw InventoryCommandError.noChanges
        }
    }
}

/// Eat or toss one unit. Both append exactly `-1` to the lowest-id member.
public struct ConsumeItemCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let itemID: UUID
    public let stockChangeID: UUID
    public let reason: StockReason
    public let occurredAt: Date

    public init?(householdID: UUID, commandID: UUID, itemID: UUID, stockChangeID: UUID,
                 reason: StockReason, occurredAt: Date = Date()) {
        guard reason == .eaten || reason == .tossed else { return nil }
        self.householdID = householdID
        self.commandID = commandID
        self.itemID = itemID
        self.stockChangeID = stockChangeID
        self.reason = reason
        self.occurredAt = occurredAt
    }

    public var event: StockEvent {
        StockEvent(id: stockChangeID, delta: -1, reason: reason, occurredAt: occurredAt)
    }
}

/// Deletes one logical item. The single terminal marker fans out to every
/// physical member resolved in the writer transaction, and the grouped reducer
/// counts that id once.
public struct DeleteItemCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let itemID: UUID
    public let stockChangeID: UUID
    public let occurredAt: Date

    public init(householdID: UUID, commandID: UUID, itemID: UUID, stockChangeID: UUID,
                occurredAt: Date = Date()) {
        self.householdID = householdID
        self.commandID = commandID
        self.itemID = itemID
        self.stockChangeID = stockChangeID
        self.occurredAt = occurredAt
    }

    public var marker: StockEvent {
        StockEvent(id: stockChangeID, delta: 0, reason: .deleted, occurredAt: occurredAt)
    }
}

/// Clear All: one causal barrier for the whole Household and no item-level
/// stock event (ADR 0009).
public struct ClearHouseholdCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let clearRecordID: UUID
    public let epochID: UUID
    public let occurredAt: Date

    public init(householdID: UUID, commandID: UUID, clearRecordID: UUID, epochID: UUID,
                occurredAt: Date = Date()) {
        self.householdID = householdID
        self.commandID = commandID
        self.clearRecordID = clearRecordID
        self.epochID = epochID
        self.occurredAt = occurredAt
    }

    /// Nil when the frontier cannot produce a valid successor revision.
    ///
    /// The frontier snapshot is part of the record's payload, so a retry must
    /// replay the record this returns rather than build a second one: the same
    /// clear-record id carrying different parents would be read as a
    /// conflicting record and drop both copies, leaving the frontier unmoved
    /// while the UI reported success.
    public func clearRecord(from reduction: InventoryEpochReduction) -> HouseholdClearRecord? {
        InventoryEpochReducer.makeClear(recordID: clearRecordID, epochID: epochID,
                                        occurredAt: occurredAt, from: reduction)
    }
}

public struct RenameHouseholdCommand: Hashable, Sendable {
    public let householdID: UUID
    public let commandID: UUID
    public let name: String

    public init(householdID: UUID, commandID: UUID, name: String) {
        self.householdID = householdID
        self.commandID = commandID
        self.name = name
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InventoryCommandError.emptyHouseholdName
        }
    }
}

/// What a fresh purchase root is stamped with, and which fields the user
/// deliberately changed.
public struct PurchaseRootMetadata: Hashable, Sendable {
    public let name: String
    public let artKey: String
    public let storage: StorageLocation
    public let purchaseDay: InventoryDay
    public let expiryDay: InventoryDay
    public let expirySource: ExpirySource
}

/// The edits to apply once to the canonical member resolved after insertion.
public struct CanonicalMetadataEdit: Hashable, Sendable {
    public let artKey: String?
    public let storage: StorageLocation?
    public let expiryDay: InventoryDay?
}

public struct PurchasePlan: Hashable, Sendable {
    public let rootMetadata: PurchaseRootMetadata
    /// Nil when the purchase establishes the metadata itself, or when the user
    /// changed nothing.
    public let canonicalEdit: CanonicalMetadataEdit?
}

/// Decides what a purchase does to the metadata of an item that already exists
/// under the same name (ADR 0011).
///
/// Replacing the whole form on every purchase would let a scan guess overwrite a
/// value the user trusts; ignoring the form would discard real intent. So the
/// new root copies what is established, and only fields the user actually
/// touched are applied to the canonical member.
public enum PurchasePlanner {
    /// The user-visible grouping rule, scoped to one household's projection:
    /// exact normalized-name match, never an expired batch. Zero-quantity and
    /// deleted groups are already absent from a projection.
    public static func match(name: String, in items: [InventoryItemSnapshot],
                             today: InventoryDay) -> InventoryItemSnapshot? {
        let key = NameKey.normalize(name)
        guard !key.isEmpty else { return nil }
        return items
            .filter { $0.normalizedName == key && !$0.isExpired(on: today) }
            .max { left, right in
                left.purchaseDay == right.purchaseDay
                    ? UUIDOrder.isBefore(left.id, right.id)
                    : left.purchaseDay < right.purchaseDay
            }
    }

    /// Plans a whole multirow save. A review-time rename can make two rows of
    /// one receipt share a name; carrying each planned row forward means the
    /// first row establishes the metadata and the second copies it, instead of
    /// both stamping their own guess and letting UUID order decide which shows.
    public static func plan(rows: [PurchaseDraft], in items: [InventoryItemSnapshot],
                            today: InventoryDay) -> [PurchasePlan] {
        var candidates = items
        var plans: [PurchasePlan] = []
        for row in rows {
            let existing = match(name: row.name, in: candidates, today: today)
            let plan = plan(for: row, matching: existing)
            plans.append(plan)

            // Represent the resulting group so a later same-name row sees it,
            // including any edit that will land on its canonical member.
            let group = candidate(for: row, plan: plan, replacing: existing)
            if let index = candidates.firstIndex(where: { $0.id == group.id }) {
                candidates[index] = group
            } else {
                candidates.append(group)
            }
        }
        return plans
    }

    private static func candidate(for row: PurchaseDraft, plan: PurchasePlan,
                                  replacing existing: InventoryItemSnapshot?)
    -> InventoryItemSnapshot {
        let metadata = plan.rootMetadata
        let edit = plan.canonicalEdit
        return InventoryItemSnapshot(
            id: existing?.id ?? row.itemID,
            memberIDs: existing.map { $0.memberIDs + [row.itemID] } ?? [row.itemID],
            name: metadata.name,
            normalizedName: NameKey.normalize(metadata.name),
            quantity: (existing?.quantity ?? 0) + row.quantity,
            artKey: edit?.artKey ?? metadata.artKey,
            storage: edit?.storage ?? metadata.storage,
            purchaseDay: metadata.purchaseDay,
            expiryDay: edit?.expiryDay ?? metadata.expiryDay,
            expirySource: metadata.expirySource)
    }

    public static func plan(for draft: PurchaseDraft,
                            matching existing: InventoryItemSnapshot?) -> PurchasePlan {
        guard let existing else {
            return PurchasePlan(
                rootMetadata: PurchaseRootMetadata(name: draft.name, artKey: draft.artKey,
                                                   storage: draft.storage,
                                                   purchaseDay: draft.purchaseDay,
                                                   expiryDay: draft.expiryDay,
                                                   expirySource: draft.expirySource),
                canonicalEdit: nil)
        }

        let explicit = draft.explicitMetadataFields
        return PurchasePlan(
            rootMetadata: PurchaseRootMetadata(name: existing.name, artKey: existing.artKey,
                                               storage: existing.storage,
                                               purchaseDay: existing.purchaseDay,
                                               expiryDay: existing.expiryDay,
                                               expirySource: existing.expirySource),
            canonicalEdit: explicit.isEmpty ? nil : CanonicalMetadataEdit(
                artKey: explicit.contains(.art) ? draft.artKey : nil,
                storage: explicit.contains(.storage) ? draft.storage : nil,
                expiryDay: explicit.contains(.expiryDay) ? draft.expiryDay : nil))
    }
}
