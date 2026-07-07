#if DEBUG
import Foundation
import SwiftData

/// The home-screen mock's inventory, for Xcode previews and the scan menu's
/// "Seed the App" action (debug builds) — populates the fridge with no
/// API key or LLM call so the grid, urgency tints, and drag-to-consume are
/// viewable anywhere, including browser-hosted simulators.
enum PreviewData {
    /// Inserts the preset items with expiries relative to today, covering
    /// every urgency tier (expired → today → soon → fresh).
    static func seed(into context: ModelContext) {
        func seed(_ name: String, _ id: ItemID, daysLeft: Int, quantity: Int = 1) {
            let expiry = Calendar.current.date(byAdding: .day, value: daysLeft, to: Date())!
            context.insert(FridgeItem(
                name: name, artKey: id.rawValue, quantity: quantity,
                purchaseDate: Date(), expiryDate: expiry))
        }

        seed("Salmon", .salmon, daysLeft: -1)
        seed("Whole Milk", .milk, daysLeft: 0)
        seed("Strawberries", .strawberry, daysLeft: 1)
        seed("Chicken", .chicken, daysLeft: 2)
        seed("Spinach", .spinach, daysLeft: 2)
        seed("Leftovers", .leftovers, daysLeft: 3)
        seed("Greek Yogurt", .yogurt, daysLeft: 5)
        seed("Orange Juice", .juice, daysLeft: 9)
        seed("Eggs", .eggs, daysLeft: 12, quantity: 12)
        seed("Apples", .apple, daysLeft: 14, quantity: 6)
        seed("Carrots", .carrot, daysLeft: 18)
        seed("Cheddar", .cheese, daysLeft: 24)
        seed("Butter", .butter, daysLeft: 30)
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
