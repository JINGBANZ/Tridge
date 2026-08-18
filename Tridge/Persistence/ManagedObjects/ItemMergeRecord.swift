import CoreData

/// A permanent exact-name identity claim between two physical purchase roots.
///
/// Endpoints are different, sorted by UUID byte order (`leftItemID` first), and
/// resolve to items in the same Household and store. The claim is immutable and
/// never deleted: duplicate claims for the same endpoints have the same union
/// effect, which makes concurrent reconciliation idempotent without a
/// CloudKit-incompatible uniqueness constraint.
@objc(ItemMergeRecord)
final class ItemMergeRecord: NSManagedObject {
    static let entityName = "ItemMergeRecord"

    @nonobjc static func fetchRequest() -> NSFetchRequest<ItemMergeRecord> {
        NSFetchRequest<ItemMergeRecord>(entityName: entityName)
    }

    @NSManaged var id: UUID?
    @NSManaged var modelVersion: Int16
    @NSManaged var leftItemID: UUID?
    @NSManaged var rightItemID: UUID?
    @NSManaged var createdAt: Date?

    @NSManaged var household: HouseholdRecord?
}
