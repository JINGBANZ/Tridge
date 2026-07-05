import XCTest
@testable import FridgeCore

/// Guards the enforced wire schema against drifting from the Swift DTOs.
final class ReceiptSchemaTests: XCTestCase {
    private var schema: [String: Any] = [:]
    private var itemSchema: [String: Any] = [:]

    override func setUpWithError() throws {
        schema = try ReceiptSchema.object()
        let items = try XCTUnwrap(schema["properties"] as? [String: Any])["items"]
        itemSchema = try XCTUnwrap((items as? [String: Any])?["items"] as? [String: Any])
    }

    func testTopLevelShape() throws {
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])),
                       ["store", "purchase_date", "items"])
    }

    func testItemShapeIsStrictAndComplete() throws {
        XCTAssertEqual(itemSchema["additionalProperties"] as? Bool, false)
        let required = Set(try XCTUnwrap(itemSchema["required"] as? [String]))
        let properties = Set(try XCTUnwrap(itemSchema["properties"] as? [String: Any]).keys)
        // Strict mode demands every property be required, and vice versa.
        XCTAssertEqual(required, properties)
        XCTAssertEqual(required, ["name", "receipt_text", "emoji", "category", "quantity",
                                  "storage", "shelf_life_days", "confidence"])
    }

    func testEnumsMatchSwiftTypes() throws {
        let properties = try XCTUnwrap(itemSchema["properties"] as? [String: Any])
        func enumValues(_ key: String) throws -> Set<String> {
            Set(try XCTUnwrap((properties[key] as? [String: Any])?["enum"] as? [String]))
        }
        XCTAssertEqual(try enumValues("category"),
                       Set(FoodCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(try enumValues("storage"),
                       Set(StorageLocation.allCases.map(\.rawValue)))
        XCTAssertEqual(try enumValues("confidence"), ["high", "low"])
    }

    func testSchemaConformingReplyRoundTripsThroughParser() throws {
        // A maximal reply that obeys the schema (nulls included) must decode.
        let reply = """
        { "store": null, "purchase_date": "2026-07-05",
          "items": [{ "name": "Whole Milk", "receipt_text": null, "emoji": "🥛",
                      "category": "dairy", "quantity": 1, "storage": "fridge",
                      "shelf_life_days": 7, "confidence": "high" }] }
        """
        let receipt = try ReceiptResponseParser.parse(reply)
        XCTAssertEqual(receipt.items.count, 1)
        XCTAssertNil(receipt.items[0].receiptText)
    }
}
