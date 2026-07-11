import Foundation

/// The curated item vocabulary. The LLM must return one of these ids (enforced
/// server-side by the scan API's JSON schema, `server/src/receipt-schema.json`),
/// and each id maps to prebuilt art — emoji in v1, swappable for custom images
/// under the same keys.
///
/// Scalability is handled in tiers: specific ids first, then the generic
/// buckets at the end (`fruit`, `vegetable`, …) for anything the list doesn't
/// name, and `unknown` as the last resort. New ids can be appended any time;
/// older app builds decode unrecognized ids as `.unknown`.
public enum ItemID: String, Codable, CaseIterable, Sendable {
    // Fruit
    case apple, banana, orange, grapes, strawberry, blueberry, lemon, peach,
         pear, watermelon, melon, pineapple, kiwi, cherry, mango, avocado, coconut
    // Vegetables
    case lettuce, spinach, broccoli, carrot, corn, cucumber, tomato, potato,
         sweetPotato = "sweet_potato", onion, garlic, pepper, mushroom, eggplant,
         peas, beans
    // Dairy & eggs
    case milk, cheese, butter, yogurt, eggs, iceCream = "ice_cream"
    // Meat
    case chicken, beef, pork, bacon, sausage, turkey, groundMeat = "ground_meat"
    // Seafood
    case fish, salmon, tuna, shrimp, crab
    // Bakery
    case bread, bagel, croissant, tortilla, cake, cookie, muffin
    // Beverages
    case juice, soda, coffee, tea, beer, wine, water
    // Pantry & snacks
    case rice, pasta, noodles, cereal, soup, cannedGoods = "canned_goods",
         sauce, oil, honey, jam, peanutButter = "peanut_butter", nuts, chips,
         crackers, chocolate, candy, popcorn
    // Prepared
    case pizza, sandwich, sushi, salad, leftovers, frozenMeal = "frozen_meal"
    // Generic buckets — used when nothing specific fits
    case fruit, vegetable, dairy, meat, seafood, bakery, beverage, grain,
         snack, condiment, frozen
    // Last resort
    case unknown

    /// v1 art: one emoji per id (duplicates are fine — custom sprites can
    /// differentiate later without touching the vocabulary).
    public var emoji: String {
        switch self {
        case .apple: "🍎"
        case .banana: "🍌"
        case .orange: "🍊"
        case .grapes: "🍇"
        case .strawberry: "🍓"
        case .blueberry: "🫐"
        case .lemon: "🍋"
        case .peach: "🍑"
        case .pear: "🍐"
        case .watermelon: "🍉"
        case .melon: "🍈"
        case .pineapple: "🍍"
        case .kiwi: "🥝"
        case .cherry: "🍒"
        case .mango: "🥭"
        case .avocado: "🥑"
        case .coconut: "🥥"
        case .lettuce: "🥬"
        case .spinach: "🥬"
        case .broccoli: "🥦"
        case .carrot: "🥕"
        case .corn: "🌽"
        case .cucumber: "🥒"
        case .tomato: "🍅"
        case .potato: "🥔"
        case .sweetPotato: "🍠"
        case .onion: "🧅"
        case .garlic: "🧄"
        case .pepper: "🫑"
        case .mushroom: "🍄"
        case .eggplant: "🍆"
        case .peas: "🫛"
        case .beans: "🫘"
        case .milk: "🥛"
        case .cheese: "🧀"
        case .butter: "🧈"
        case .yogurt: "🥣"
        case .eggs: "🥚"
        case .iceCream: "🍦"
        case .chicken: "🍗"
        case .beef: "🥩"
        case .pork: "🍖"
        case .bacon: "🥓"
        case .sausage: "🌭"
        case .turkey: "🦃"
        case .groundMeat: "🥩"
        case .fish: "🐟"
        case .salmon: "🐟"
        case .tuna: "🐟"
        case .shrimp: "🦐"
        case .crab: "🦀"
        case .bread: "🍞"
        case .bagel: "🥯"
        case .croissant: "🥐"
        case .tortilla: "🫓"
        case .cake: "🍰"
        case .cookie: "🍪"
        case .muffin: "🧁"
        case .juice: "🧃"
        case .soda: "🥤"
        case .coffee: "☕️"
        case .tea: "🍵"
        case .beer: "🍺"
        case .wine: "🍷"
        case .water: "💧"
        case .rice: "🍚"
        case .pasta: "🍝"
        case .noodles: "🍜"
        case .cereal: "🥣"
        case .soup: "🍲"
        case .cannedGoods: "🥫"
        case .sauce: "🫙"
        case .oil: "🫒"
        case .honey: "🍯"
        case .jam: "🫙"
        case .peanutButter: "🥜"
        case .nuts: "🥜"
        case .chips: "🍟"
        case .crackers: "🍘"
        case .chocolate: "🍫"
        case .candy: "🍬"
        case .popcorn: "🍿"
        case .pizza: "🍕"
        case .sandwich: "🥪"
        case .sushi: "🍱"
        case .salad: "🥗"
        case .leftovers: "🥡"
        case .frozenMeal: "🧊"
        case .fruit: "🍏"
        case .vegetable: "🥬"
        case .dairy: "🥛"
        case .meat: "🍖"
        case .seafood: "🦞"
        case .bakery: "🥖"
        case .beverage: "🥤"
        case .grain: "🌾"
        case .snack: "🍿"
        case .condiment: "🧂"
        case .frozen: "❄️"
        case .unknown: "🛒"
        }
    }
}

/// What an item *is* (Storage is where it *lives*). Never stored or sent over
/// the wire — derived from the item's `ItemID` via `foodCategory` below, so
/// existing items pick up categories with no migration and no LLM change.
public enum FoodCategory: String, CaseIterable, Sendable {
    case produce, dairy, meat, seafood, bakery, drinks, snacks, condiments, other

    public var label: String {
        switch self {
        case .produce: "Produce"
        case .dairy: "Dairy"
        case .meat: "Meat"
        case .seafood: "Seafood"
        case .bakery: "Bakery"
        case .drinks: "Drinks"
        case .snacks: "Snacks"
        case .condiments: "Condiments"
        case .other: "Other"
        }
    }
}

extension ItemID {
    /// Exhaustive by design: a new vocabulary id can't ship without a category.
    public var foodCategory: FoodCategory {
        switch self {
        case .apple, .banana, .orange, .grapes, .strawberry, .blueberry, .lemon,
             .peach, .pear, .watermelon, .melon, .pineapple, .kiwi, .cherry,
             .mango, .avocado, .coconut, .fruit,
             .lettuce, .spinach, .broccoli, .carrot, .corn, .cucumber, .tomato,
             .potato, .sweetPotato, .onion, .garlic, .pepper, .mushroom,
             .eggplant, .peas, .beans, .vegetable:
            .produce
        case .milk, .cheese, .butter, .yogurt, .eggs, .dairy:
            .dairy
        case .chicken, .beef, .pork, .bacon, .sausage, .turkey, .groundMeat, .meat:
            .meat
        case .fish, .salmon, .tuna, .shrimp, .crab, .seafood:
            .seafood
        case .bread, .bagel, .croissant, .tortilla, .cake, .cookie, .muffin, .bakery:
            .bakery
        case .juice, .soda, .coffee, .tea, .beer, .wine, .water, .beverage:
            .drinks
        // Ice cream sits with the treats, not the dairy case — that's how
        // people browse for it.
        case .chips, .crackers, .chocolate, .candy, .popcorn, .nuts, .iceCream, .snack:
            .snacks
        case .sauce, .oil, .honey, .jam, .peanutButter, .condiment:
            .condiments
        // Grains/pantry staples and prepared food land in Other until the
        // vocabulary earns them a category of their own.
        case .rice, .pasta, .noodles, .cereal, .soup, .cannedGoods, .grain,
             .pizza, .sandwich, .sushi, .salad, .leftovers, .frozenMeal, .frozen,
             .unknown:
            .other
        }
    }
}

public enum StorageLocation: String, Codable, CaseIterable, Sendable {
    case fridge, freezer, pantry

    public var label: String {
        switch self {
        case .fridge: "Fridge"
        case .freezer: "Freezer"
        case .pantry: "Pantry"
        }
    }
}

public enum ExpirySource: String, Codable, Sendable {
    case llmEstimate, userSet, scannedLabel
}

public enum ItemStatus: String, Codable, Sendable {
    case active, eaten, tossed
}
