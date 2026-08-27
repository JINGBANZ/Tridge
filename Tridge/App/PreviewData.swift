#if DEBUG
import Foundation

/// The home-screen mock's inventory, for Xcode previews and the scan menu's
/// "Seed the App" action (debug builds) — populates the fridge with no
/// API key or LLM call so the grid, urgency tints, and drag-to-consume are
/// viewable anywhere, including browser-hosted simulators.
enum PreviewData {
    /// One preset row, expressed relative to today so every urgency tier
    /// (expired → today → soon → fresh) is covered whenever it is seeded.
    private struct Row {
        let name: String
        let art: ItemID
        let daysLeft: Int
        var quantity: Int64 = 1
        var storage: StorageLocation = .fridge
    }

    private static let rows: [Row] = [
        Row(name: "Salmon", art: .salmon, daysLeft: -1),
        Row(name: "Whole Milk", art: .milk, daysLeft: 0),
        Row(name: "Strawberries", art: .strawberry, daysLeft: 1),
        Row(name: "Chicken", art: .chicken, daysLeft: 2),
        Row(name: "Spinach", art: .spinach, daysLeft: 2),
        Row(name: "Leftovers", art: .leftovers, daysLeft: 3),
        Row(name: "Sourdough", art: .bread, daysLeft: 4, storage: .pantry),
        Row(name: "Greek Yogurt", art: .yogurt, daysLeft: 5),
        Row(name: "Orange Juice", art: .juice, daysLeft: 9),
        Row(name: "Eggs", art: .eggs, daysLeft: 12, quantity: 12),
        Row(name: "Apples", art: .apple, daysLeft: 14, quantity: 6),
        Row(name: "Carrots", art: .carrot, daysLeft: 18),
        Row(name: "Cheddar", art: .cheese, daysLeft: 24),
        Row(name: "Butter", art: .butter, daysLeft: 30),
        // Freezer/pantry rows keep the filter button exercisable in seeded builds.
        Row(name: "Shrimp", art: .shrimp, daysLeft: 45, storage: .freezer),
        Row(name: "Frozen Peas", art: .peas, daysLeft: 60, storage: .freezer),
        Row(name: "Ice Cream", art: .iceCream, daysLeft: 90, storage: .freezer),
    ]

    /// The preset inventory as ordinary purchases, so the debug seed goes
    /// through the repository like any other confirmation — one fresh
    /// frontier-stamped root and one `acquired` operation per row — rather than
    /// writing rows the projector never saw created.
    static func seedPurchases(today: InventoryDay = InventoryDay.today(),
                              now: Date = Date()) -> [PurchaseDraft] {
        rows.map { row in
            PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: row.name,
                          quantity: row.quantity, artKey: row.art.rawValue,
                          storage: row.storage, purchaseDay: today,
                          expiryDay: today.adding(days: row.daysLeft) ?? today,
                          expirySource: .llmEstimate, explicitMetadataFields: [],
                          occurredAt: now)
        }
    }

    /// The same preset inventory as the value snapshots a projection would
    /// produce, so Xcode previews render Home without a store at all.
    static func previewItems(today: InventoryDay = InventoryDay.today())
    -> [InventoryItemSnapshot] {
        rows.map { row in
            let id = UUID()
            return InventoryItemSnapshot(
                id: id, memberIDs: [id], name: row.name,
                normalizedName: NameKey.normalize(row.name), quantity: row.quantity,
                artKey: row.art.rawValue, storage: row.storage, purchaseDay: today,
                expiryDay: today.adding(days: row.daysLeft) ?? today,
                expirySource: .llmEstimate)
        }
        .sorted { $0.expiryDay < $1.expiryDay }
    }

    /// The purchase-history side of the same fixture, which is what the manual
    /// add sheet ranks its quick-fill chips from.
    static func previewHistory(today: InventoryDay = InventoryDay.today(),
                               now: Date = Date()) -> [PhysicalItemSnapshot] {
        rows.map { row in
            PhysicalItemSnapshot(
                id: UUID(), name: row.name, inventoryContext: [UUID()],
                artKey: row.art.rawValue, storage: row.storage, purchaseDay: today,
                expiryDay: today.adding(days: row.daysLeft) ?? today,
                expirySource: .llmEstimate, createdAt: now, modifiedAt: now)
        }
    }

    /// An account scope for previews. Any canonical 64-character digest works;
    /// nothing here ever reaches a store or a notification identifier.
    static let previewAccountScope = AccountScopeHash(
        digest: String(repeating: "a", count: 64))!

    static var previewAccountContext: AccountSessionContext {
        AccountSessionContext(
            generationContext: AccountGenerationContext(accountScope: previewAccountScope),
            privateStoreIdentifier: "preview.private",
            sharedStoreIdentifier: "preview.shared")
    }
}

/// A repository that answers previews from a fixed projection and refuses to
/// write. Previews never reach it — the session is seeded directly — but the
/// session's initializer needs something to hold.
struct PreviewInventoryRepository: InventoryRepository {
    let fixed: HouseholdProjection

    func projection(of householdID: UUID,
                    today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func addManualItem(_ command: AddManualItemCommand,
                       today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func addReviewedRows(_ command: AddReviewedRowsCommand,
                         today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func updateItem(_ command: UpdateItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func consumeItem(_ command: ConsumeItemCommand,
                     today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func deleteItem(_ command: DeleteItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection { fixed }

    func clearActiveHousehold(_ command: ClearHouseholdCommand,
                              today: InventoryDay) async throws -> HouseholdProjection {
        fixed
    }

    func renameOwnedHousehold(_ command: RenameHouseholdCommand) async throws -> HouseholdSnapshot {
        throw InventoryRepositoryError.householdNotOwned
    }
}
#endif
