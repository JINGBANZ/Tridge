import CoreData

/// One immutable stock operation. Household members compose these instead of
/// overwriting a scalar quantity, so no concurrent add or consume is lost to a
/// last-writer-wins merge. Nothing edits a row after insertion.
///
/// `id` is the originating command's id: an identical retry reduces to one
/// operation, a conflicting payload for the same id is an integrity error.
@objc(StockChangeRecord)
final class StockChangeRecord: NSManagedObject {
    static let entityName = "StockChangeRecord"

    @nonobjc static func fetchRequest() -> NSFetchRequest<StockChangeRecord> {
        NSFetchRequest<StockChangeRecord>(entityName: entityName)
    }

    @NSManaged var id: UUID?
    @NSManaged var modelVersion: Int16
    @NSManaged var delta: Int64
    @NSManaged var reasonRaw: String?
    @NSManaged var occurredAt: Date?

    @NSManaged var item: FridgeItemRecord?
}
