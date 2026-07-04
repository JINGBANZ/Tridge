#if DEBUG
import Foundation
import SwiftData

/// In-memory container seeded with the home-screen mock's inventory, for
/// Xcode previews only.
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: FridgeItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        func seed(_ name: String, _ emoji: String, _ category: FoodCategory,
                  daysLeft: Int, quantity: Int = 1) {
            let expiry = Calendar.current.date(byAdding: .day, value: daysLeft, to: Date())!
            container.mainContext.insert(FridgeItem(
                name: name, artKey: emoji, category: category, quantity: quantity,
                purchaseDate: Date(), expiryDate: expiry, store: "Trader Joe's"))
        }

        seed("Salmon", "🐟", .seafood, daysLeft: -1)
        seed("Whole Milk", "🥛", .dairy, daysLeft: 0)
        seed("Strawberries", "🍓", .produce, daysLeft: 1)
        seed("Chicken", "🍗", .meat, daysLeft: 2)
        seed("Spinach", "🥬", .produce, daysLeft: 2)
        seed("Leftovers", "🍝", .leftovers, daysLeft: 3)
        seed("Greek Yogurt", "🥣", .dairy, daysLeft: 5)
        seed("Orange Juice", "🧃", .beverage, daysLeft: 9)
        seed("Eggs", "🥚", .dairy, daysLeft: 12, quantity: 12)
        seed("Apples", "🍎", .produce, daysLeft: 14, quantity: 6)
        seed("Carrots", "🥕", .produce, daysLeft: 18)
        seed("Cheddar", "🧀", .dairy, daysLeft: 24)
        seed("Butter", "🧈", .dairy, daysLeft: 30)
        return container
    }()
}
#endif
