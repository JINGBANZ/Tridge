import XCTest
@testable import FridgeCore

/// Guards the enforced wire schema against drifting from the Swift DTOs.
final class ReceiptSchemaTests: XCTestCase {
    private var schema: [String: Any] = [:]
    private var itemSchema: [String: Any] = [:]

    override func setUpWithError() throws {
        schema = ReceiptSchema.object()
        let items = try XCTUnwrap(schema["properties"] as? [String: Any])["items"]
        itemSchema = try XCTUnwrap((items as? [String: Any])?["items"] as? [String: Any])
    }

    func testSchemaSerializesAsJSON() throws {
        // Strict structured outputs rejects anything that isn't plain JSON.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ReceiptSchema.object()))
    }

    func testTopLevelShape() throws {
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(schema["required"] as? [String]), ["items"])
    }

    func testItemShapeIsStrictAndComplete() throws {
        XCTAssertEqual(itemSchema["additionalProperties"] as? Bool, false)
        let required = Set(try XCTUnwrap(itemSchema["required"] as? [String]))
        let properties = Set(try XCTUnwrap(itemSchema["properties"] as? [String: Any]).keys)
        // Strict mode demands every property be required, and vice versa.
        XCTAssertEqual(required, properties)
        XCTAssertEqual(required, ["id", "name", "receipt_text", "quantity", "shelf_life_days"])
    }

    func testIDEnumIsExactlyTheCuratedVocabulary() throws {
        let properties = try XCTUnwrap(itemSchema["properties"] as? [String: Any])
        let idEnum = try XCTUnwrap((properties["id"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(idEnum, ItemID.allCases.map(\.rawValue))
        XCTAssertTrue(idEnum.contains("unknown"), "the fallback id must stay in the vocabulary")
    }

    func testEveryVocabularyIDHasArt() {
        for id in ItemID.allCases {
            XCTAssertFalse(id.emoji.isEmpty, "\(id.rawValue) has no emoji")
        }
    }

    func testSchemaConformingReplyRoundTripsThroughParser() throws {
        // A maximal reply that obeys the schema (nulls included) must decode.
        let reply = """
        { "items": [{ "id": "milk", "name": "Whole Milk", "receipt_text": null,
                      "quantity": 1, "shelf_life_days": 7 },
                    { "id": "unknown", "name": "Unknown item", "receipt_text": "TJ 94823 MISC",
                      "quantity": 1, "shelf_life_days": 3 }] }
        """
        let receipt = try ReceiptResponseParser.parse(reply)
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertNil(receipt.items[0].receiptText)
        XCTAssertEqual(receipt.items[1].id, .unknown)
    }
}
