import XCTest
@testable import FridgeCore

/// The curated `ItemID` vocabulary and its on-device art mapping.
final class ItemIDTests: XCTestCase {
    func testEveryVocabularyIDHasArt() {
        for id in ItemID.allCases {
            XCTAssertFalse(id.emoji.isEmpty, "\(id.rawValue) has no emoji")
        }
    }

    /// Spot-checks the id → Food Category mapping, one per category plus the
    /// deliberate judgment calls (eggs → dairy, ice cream → snacks, grains and
    /// prepared food → other). The switch is exhaustive, so full coverage is
    /// compiler-enforced.
    func testFoodCategoryMapping() {
        let expectations: [ItemID: FoodCategory] = [
            .strawberry: .produce, .spinach: .produce, .fruit: .produce, .vegetable: .produce,
            .milk: .dairy, .eggs: .dairy, .dairy: .dairy,
            .chicken: .meat, .meat: .meat,
            .salmon: .seafood, .shrimp: .seafood, .seafood: .seafood,
            .bread: .bakery, .bakery: .bakery,
            .juice: .drinks, .beverage: .drinks,
            .iceCream: .snacks, .chips: .snacks, .snack: .snacks,
            .peanutButter: .condiments, .condiment: .condiments,
            .rice: .other, .pasta: .other, .grain: .other,
            .pizza: .other, .leftovers: .other, .frozen: .other, .unknown: .other,
        ]
        for (id, category) in expectations {
            XCTAssertEqual(id.foodCategory, category,
                           "\(id.rawValue) should be \(category.rawValue)")
        }
    }

    func testEveryFoodCategoryHasALabel() {
        for category in FoodCategory.allCases {
            XCTAssertFalse(category.label.isEmpty, "\(category.rawValue) has no label")
        }
    }
}
