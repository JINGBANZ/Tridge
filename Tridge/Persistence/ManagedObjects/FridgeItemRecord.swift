import CoreData

/// One physical purchase root: the durable anchor a purchase's stock history
/// hangs from. Several roots can project as one logical Home row once permanent
/// `ItemMergeRecord` claims join them.
///
/// Quantity, status, deletion, urgency, and Food Category are deliberately
/// absent — they derive from the immutable stock events, the expiry day, and the
/// art key. Receipt text is never persisted.
@objc(FridgeItemRecord)
final class FridgeItemRecord: NSManagedObject {
    static let entityName = "FridgeItemRecord"

    @nonobjc static func fetchRequest() -> NSFetchRequest<FridgeItemRecord> {
        NSFetchRequest<FridgeItemRecord>(entityName: entityName)
    }

    @NSManaged var id: UUID?
    @NSManaged var modelVersion: Int16
    @NSManaged var name: String?
    /// The immutable identity key; saved names are read-only (ADR 0005).
    @NSManaged var normalizedName: String?
    /// The complete Household frontier this root captured when it was created,
    /// in `InventoryEpochCodec`'s canonical encoding.
    @NSManaged var inventoryEpochContextRaw: String?
    @NSManaged var artKey: String?
    @NSManaged var storageRaw: String?
    /// Signed Gregorian day ordinals relative to 1970-01-01 — never an absolute
    /// midnight instant (ADR 0003).
    @NSManaged var purchaseDay: Int32
    @NSManaged var expiryDay: Int32
    @NSManaged var expirySourceRaw: String?
    @NSManaged var createdAt: Date?
    @NSManaged var modifiedAt: Date?

    @NSManaged var household: HouseholdRecord?
    @NSManaged var stockChanges: Set<StockChangeRecord>
}
