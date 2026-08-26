#if DEBUG
import Foundation
import SwiftData

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
        var quantity: Int = 1
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
                          quantity: Int64(row.quantity), artKey: row.art.rawValue,
                          storage: row.storage, purchaseDay: today,
                          expiryDay: today.adding(days: row.daysLeft) ?? today,
                          expirySource: .llmEstimate, explicitMetadataFields: [],
                          occurredAt: now)
        }
    }

    /// Inserts the preset items into the legacy SwiftData store the shipping
    /// build still runs on.
    static func seed(into context: ModelContext) {
        for row in rows {
            let expiry = Calendar.current.date(byAdding: .day, value: row.daysLeft, to: Date())!
            context.insert(FridgeItem(
                name: row.name, artKey: row.art.rawValue, quantity: row.quantity,
                storage: row.storage, purchaseDate: Date(), expiryDate: expiry))
        }
        try? context.save() // hand-made contexts don't autosave
    }

    /// In-memory container pre-seeded for Xcode previews.
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: FridgeItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // A throwaway context: the static initializer is nonisolated, so the
        // main-actor-bound mainContext is off limits here.
        seed(into: ModelContext(container))
        return container
    }()
}
#endif
