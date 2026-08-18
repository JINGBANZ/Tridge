import CoreData

/// One Household. Its persistent store — not an optional participant field —
/// decides whether it is owned (private store) or received (shared store).
///
/// Every attribute is optional in the model so it satisfies CloudKit's rules;
/// the repository fills and validates them, and mapping to a value snapshot
/// rejects anything corrupt rather than leaking optionals into the domain.
/// `@objc` pins the Objective-C class name the model refers to, so the runtime
/// lookup never depends on the Swift module name.
@objc(HouseholdRecord)
final class HouseholdRecord: NSManagedObject {
    static let entityName = "HouseholdRecord"

    @nonobjc static func fetchRequest() -> NSFetchRequest<HouseholdRecord> {
        NSFetchRequest<HouseholdRecord>(entityName: entityName)
    }

    @NSManaged var id: UUID?
    @NSManaged var modelVersion: Int16
    @NSManaged var name: String?
    /// The root of the causal epoch graph: revision 0, and the frontier until
    /// the first Clear All.
    @NSManaged var initialInventoryEpochID: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var modifiedAt: Date?

    @NSManaged var items: Set<FridgeItemRecord>
    @NSManaged var itemMerges: Set<ItemMergeRecord>
    @NSManaged var clearEvents: Set<HouseholdClearRecord>
}
