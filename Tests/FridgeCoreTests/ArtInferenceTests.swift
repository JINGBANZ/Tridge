import XCTest
@testable import FridgeCore

final class ArtInferenceTests: XCTestCase {
    func testExactVocabularyHits() {
        XCTAssertEqual(ArtInference.itemID(for: "Milk"), .milk)
        XCTAssertEqual(ArtInference.itemID(for: "Ice Cream"), .iceCream)
        XCTAssertEqual(ArtInference.itemID(for: "sweet potato"), .sweetPotato)
    }

    func testSynonymHits() {
        XCTAssertEqual(ArtInference.itemID(for: "Yoghurt"), .yogurt)
        XCTAssertEqual(ArtInference.itemID(for: "Aubergine"), .eggplant)
        XCTAssertEqual(ArtInference.itemID(for: "Steak"), .beef)
    }

    func testPluralFallsBackToSingular() {
        XCTAssertEqual(ArtInference.itemID(for: "Peppers"), .pepper)
        XCTAssertEqual(ArtInference.itemID(for: "Tomatoes"), .tomato)
        XCTAssertEqual(ArtInference.itemID(for: "Sweet Potatoes"), .sweetPotato)
    }

    func testTokenMatchPrefersHeadNoun() {
        XCTAssertEqual(ArtInference.itemID(for: "Chocolate Milk"), .milk)
        XCTAssertEqual(ArtInference.itemID(for: "Jalapeño Peppers"), .pepper)
        XCTAssertEqual(ArtInference.itemID(for: "Sourdough Bread"), .bread)
    }

    func testTypoWithinOneEdit() {
        XCTAssertEqual(ArtInference.itemID(for: "Bannana"), .banana)
        XCTAssertEqual(ArtInference.itemID(for: "Brocoli"), .broccoli)
    }

    func testTwoEditsDoNotMatch() {
        XCTAssertEqual(ArtInference.itemID(for: "Bannnana"), .unknown)
    }

    func testUnknownFallback() {
        XCTAssertEqual(ArtInference.itemID(for: "Mooncake"), .unknown)
        XCTAssertEqual(ArtInference.itemID(for: ""), .unknown)
        XCTAssertEqual(ArtInference.itemID(for: "   "), .unknown)
    }

    func testDeterminism() {
        for _ in 0..<3 {
            XCTAssertEqual(ArtInference.itemID(for: "Jalapeño Peppers"),
                           ArtInference.itemID(for: "jalapeno  PEPPERS"))
        }
    }
}
