import XCTest
@testable import FridgeCore

/// The curated `ItemID` vocabulary and its on-device art mapping.
final class ItemIDTests: XCTestCase {
    func testEveryVocabularyIDHasArt() {
        for id in ItemID.allCases {
            XCTAssertFalse(id.emoji.isEmpty, "\(id.rawValue) has no emoji")
        }
    }
}
