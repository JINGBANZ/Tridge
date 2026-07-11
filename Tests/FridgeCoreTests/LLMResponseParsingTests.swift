import XCTest
@testable import FridgeCore

final class LLMResponseParsingTests: XCTestCase {
    private let sampleJSON = """
    { "items": [
        { "id": "milk", "name": "Whole Milk", "receipt_text": "TJ WHL MLK 1GAL",
          "quantity": 1, "shelf_life_days": 7 },
        { "id": "eggs", "name": "Eggs", "receipt_text": "LG EGGS DOZEN",
          "quantity": 12, "shelf_life_days": 18 }
      ] }
    """

    func testParsesPlainJSON() throws {
        let receipt = try ReceiptResponseParser.parse(sampleJSON)
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertEqual(receipt.items[0].id, .milk)
        XCTAssertEqual(receipt.items[0].name, "Whole Milk")
        XCTAssertEqual(receipt.items[0].receiptText, "TJ WHL MLK 1GAL")
        XCTAssertEqual(receipt.items[1].id, .eggs)
        XCTAssertEqual(receipt.items[1].quantity, 12)
        XCTAssertEqual(receipt.items[1].shelfLifeDays, 18)
    }

    func testParsesFencedJSON() throws {
        let fenced = "```json\n\(sampleJSON)\n```"
        XCTAssertEqual(try ReceiptResponseParser.parse(fenced).items.count, 2)
    }

    func testParsesFenceWithoutLanguageTag() throws {
        let fenced = "```\n\(sampleJSON)\n```"
        XCTAssertEqual(try ReceiptResponseParser.parse(fenced).items.count, 2)
    }

    func testParsesJSONSurroundedByProse() throws {
        let chatty = "Here is the extracted data:\n\(sampleJSON)\nLet me know if you need more."
        XCTAssertEqual(try ReceiptResponseParser.parse(chatty).items.count, 2)
    }

    func testUnrecognizedIDFallsBackToUnknown() throws {
        // A vocabulary id added server-side later must not break older builds.
        let json = """
        { "items": [{ "id": "dragonfruit", "name": "Dragon Fruit",
                      "receipt_text": "DRGN FRT", "quantity": 1, "shelf_life_days": 5 }] }
        """
        let item = try ReceiptResponseParser.parse(json).items[0]
        XCTAssertEqual(item.id, .unknown)
        XCTAssertEqual(item.name, "Dragon Fruit", "the free-text name is preserved")
    }

    func testMissingOptionalFieldsGetDefaults() throws {
        let json = #"{ "items": [{ "id": "bread" }] }"#
        let item = try ReceiptResponseParser.parse(json).items[0]
        XCTAssertEqual(item.id, .bread)
        XCTAssertEqual(item.name, "Unknown item")
        XCTAssertEqual(item.quantity, 1)
        XCTAssertEqual(item.shelfLifeDays, 7)
        XCTAssertNil(item.receiptText)
        XCTAssertEqual(item.storage, .fridge)
    }

    func testStorageDecodes() throws {
        let json = """
        { "items": [{ "id": "shrimp", "name": "Shrimp", "quantity": 1,
                      "shelf_life_days": 45, "storage": "freezer" }] }
        """
        XCTAssertEqual(try ReceiptResponseParser.parse(json).items[0].storage, .freezer)
    }

    func testUnrecognizedStorageFallsBackToFridge() throws {
        // A storage value outside the enum (schema drift, older server) must
        // degrade to the fridge default, never fail the item.
        let json = """
        { "items": [{ "id": "milk", "name": "Milk", "quantity": 1,
                      "shelf_life_days": 7, "storage": "cellar" }] }
        """
        XCTAssertEqual(try ReceiptResponseParser.parse(json).items[0].storage, .fridge)
    }

    func testNullReceiptTextDecodes() throws {
        let json = """
        { "items": [{ "id": "milk", "name": "Milk", "receipt_text": null,
                      "quantity": 1, "shelf_life_days": 7 }] }
        """
        XCTAssertNil(try ReceiptResponseParser.parse(json).items[0].receiptText)
    }

    func testQuantityClampedToAtLeastOne() throws {
        let json = """
        { "items": [{ "id": "milk", "name": "Milk", "quantity": 0 },
                    { "id": "juice", "name": "Juice", "quantity": -3 }] }
        """
        let receipt = try ReceiptResponseParser.parse(json)
        XCTAssertEqual(receipt.items[0].quantity, 1)
        XCTAssertEqual(receipt.items[1].quantity, 1)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try ReceiptResponseParser.parse("Sorry, I can't read this receipt."))
        XCTAssertThrowsError(try ReceiptResponseParser.parse("{ \"items\": [ truncated"))
        XCTAssertThrowsError(try ReceiptResponseParser.parse(""))
    }

    func testSchemaConformingReplyRoundTripsThroughParser() throws {
        // A maximal reply that obeys the server's wire schema (nulls included)
        // must decode. The schema itself now lives in server/; this asserts the
        // app's parser still accepts a conforming reply end to end.
        let reply = """
        { "items": [{ "id": "milk", "name": "Whole Milk", "receipt_text": null,
                      "quantity": 1, "shelf_life_days": 7, "storage": "fridge" },
                    { "id": "unknown", "name": "Unknown item", "receipt_text": "TJ 94823 MISC",
                      "quantity": 1, "shelf_life_days": 3, "storage": "freezer" }] }
        """
        let receipt = try ReceiptResponseParser.parse(reply)
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertNil(receipt.items[0].receiptText)
        XCTAssertEqual(receipt.items[1].id, .unknown)
        XCTAssertEqual(receipt.items[1].storage, .freezer)
    }
}
