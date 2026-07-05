import XCTest
@testable import FridgeCore

final class LLMResponseParsingTests: XCTestCase {
    private let sampleJSON = """
    { "store": "Trader Joe's", "purchase_date": "2026-07-04",
      "items": [
        { "name": "Whole Milk", "receipt_text": "TJ WHL MLK 1GAL", "emoji": "🥛",
          "category": "dairy", "quantity": 1, "storage": "fridge",
          "shelf_life_days": 7, "confidence": "high" },
        { "name": "Eggs", "receipt_text": "LG EGGS DOZEN", "emoji": "🥚",
          "category": "dairy", "quantity": 12, "storage": "fridge",
          "shelf_life_days": 18, "confidence": "high" }
      ] }
    """

    func testParsesPlainJSON() throws {
        let receipt = try ReceiptResponseParser.parse(sampleJSON)
        XCTAssertEqual(receipt.store, "Trader Joe's")
        XCTAssertEqual(receipt.purchaseDate, "2026-07-04")
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertEqual(receipt.items[0].name, "Whole Milk")
        XCTAssertEqual(receipt.items[0].receiptText, "TJ WHL MLK 1GAL")
        XCTAssertEqual(receipt.items[0].emoji, "🥛")
        XCTAssertEqual(receipt.items[0].category, .dairy)
        XCTAssertEqual(receipt.items[1].quantity, 12)
        XCTAssertEqual(receipt.items[1].shelfLifeDays, 18)
        XCTAssertEqual(receipt.items[0].confidence, .high)
    }

    func testParsesFencedJSON() throws {
        let fenced = "```json\n\(sampleJSON)\n```"
        let receipt = try ReceiptResponseParser.parse(fenced)
        XCTAssertEqual(receipt.items.count, 2)
    }

    func testParsesFenceWithoutLanguageTag() throws {
        let fenced = "```\n\(sampleJSON)\n```"
        XCTAssertEqual(try ReceiptResponseParser.parse(fenced).store, "Trader Joe's")
    }

    func testParsesJSONSurroundedByProse() throws {
        let chatty = "Here is the extracted data:\n\(sampleJSON)\nLet me know if you need more."
        XCTAssertEqual(try ReceiptResponseParser.parse(chatty).items.count, 2)
    }

    func testUnknownCategoryAndStorageFallBack() throws {
        let json = """
        { "store": null, "purchase_date": null,
          "items": [{ "name": "Mystery", "receipt_text": "X", "emoji": "🥫",
                      "category": "cryogenics", "quantity": 1, "storage": "cellar",
                      "shelf_life_days": 5, "confidence": "low" }] }
        """
        let item = try ReceiptResponseParser.parse(json).items[0]
        XCTAssertEqual(item.category, .other)
        XCTAssertNil(item.storage, "unknown storage is left nil for the app's default to fill")
    }

    func testMissingOptionalFieldsGetDefaults() throws {
        let json = #"{ "store": null, "purchase_date": null, "items": [{ "name": "Bread" }] }"#
        let item = try ReceiptResponseParser.parse(json).items[0]
        XCTAssertEqual(item.quantity, 1)
        XCTAssertEqual(item.shelfLifeDays, 7)
        XCTAssertEqual(item.confidence, .low)
        XCTAssertEqual(item.emoji, "")
        XCTAssertNil(item.receiptText)
    }

    func testQuantityClampedToAtLeastOne() throws {
        let json = """
        { "store": null, "purchase_date": null,
          "items": [{ "name": "Milk", "quantity": 0 },
                    { "name": "Juice", "quantity": -3 }] }
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

    func testPurchaseDateValue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let receipt = try ReceiptResponseParser.parse(sampleJSON)
        let date = try XCTUnwrap(receipt.purchaseDateValue(calendar: calendar))
        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(calendar.component(.month, from: date), 7)
        XCTAssertEqual(calendar.component(.day, from: date), 4)

        let bad = ParsedReceipt(store: nil, purchaseDate: "not-a-date", items: [])
        XCTAssertNil(bad.purchaseDateValue(calendar: calendar))
    }
}
