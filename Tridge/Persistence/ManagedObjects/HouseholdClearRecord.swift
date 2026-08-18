import CoreData

/// One immutable edge in a Household's causal epoch graph — the only thing
/// Clear All writes (ADR 0009). It carries no item-level event, so an item that
/// arrives from an offline peer after the clear is judged by its captured
/// context rather than by wall-clock time.
///
/// `parentEpochIDsRaw` is the entire frontier the clearing device could see, in
/// `InventoryEpochCodec`'s canonical encoding; `revision` is one more than the
/// greatest parent's. Two offline clears from the same frontier make two leaves,
/// not a winner and a loser. `HouseholdClearEvent` is the value form the Linux
/// reducer works with.
@objc(HouseholdClearRecord)
final class HouseholdClearRecord: NSManagedObject {
    static let entityName = "HouseholdClearRecord"

    @nonobjc static func fetchRequest() -> NSFetchRequest<HouseholdClearRecord> {
        NSFetchRequest<HouseholdClearRecord>(entityName: entityName)
    }

    @NSManaged var id: UUID?
    @NSManaged var modelVersion: Int16
    @NSManaged var epochID: UUID?
    @NSManaged var parentEpochIDsRaw: String?
    @NSManaged var revision: Int64
    @NSManaged var occurredAt: Date?

    @NSManaged var household: HouseholdRecord?
}
