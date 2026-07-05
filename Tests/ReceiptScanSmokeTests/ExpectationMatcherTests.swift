import XCTest
@testable import FridgeCore

/// Offline tests for the expectation matcher itself — these always run, so a
/// broken matcher can't silently green-light the live smoke test.
final class ExpectationMatcherTests: XCTestCase {
    private func makeReceipt() -> ParsedReceipt {
        ParsedReceipt(items: [
            ParsedItem(id: .milk, name: "Whole Milk", receiptText: "TJ WHL MLK 1GAL",
                       quantity: 1, shelfLifeDays: 7),
            ParsedItem(id: .eggs, name: "Large Eggs", receiptText: "LG EGGS DOZEN",
                       quantity: 12, shelfLifeDays: 21),
        ])
    }

    private func decode(_ json: String) throws -> ReceiptExpectation {
        try JSONDecoder().decode(ReceiptExpectation.self, from: Data(json.utf8))
    }

    func testFullySatisfiedExpectationReportsNothing() throws {
        let expectation = try decode("""
        { "min_items": 2, "max_items": 2,
          "items": [
            { "name": ["whole milk", "milk"], "id": "milk", "quantity": 1,
              "shelf_life_days": { "min": 3, "max": 14 } },
            { "name": "eggs", "id": "eggs", "quantity": 12 }
          ],
          "absent": ["bag", "tax"] }
        """)
        XCTAssertEqual(expectation.mismatches(in: makeReceipt()), [])
    }

    func testMissingItemAndFieldMismatchesAreReported() throws {
        let expectation = try decode("""
        { "items": [
            { "name": "strawberries" },
            { "name": "milk", "id": "cheese", "quantity": 2, "shelf_life_days": { "max": 5 } }
          ] }
        """)
        let problems = expectation.mismatches(in: makeReceipt())
        XCTAssertEqual(problems.count, 4)
        XCTAssertTrue(problems.contains { $0.contains("strawberries") })
        XCTAssertTrue(problems.contains { $0.contains("id milk, expected cheese") })
        XCTAssertTrue(problems.contains { $0.contains("quantity 1, expected 2") })
        XCTAssertTrue(problems.contains { $0.contains("expected ≤ 5d") })
    }

    func testCountBoundsAndForbiddenKeywords() throws {
        let expectation = try decode("""
        { "min_items": 3,
          "items": [ { "name": "milk" } ],
          "absent": ["eggs"] }
        """)
        let problems = expectation.mismatches(in: makeReceipt())
        XCTAssertTrue(problems.contains { $0.contains("expected ≥ 3") })
        XCTAssertTrue(problems.contains { $0.contains("forbidden keyword \"eggs\"") })
    }

    func testTwoExpectedItemsCannotClaimTheSameParsedItem() throws {
        // Both match "Whole Milk"; only one parsed milk exists, so the second
        // expected entry must be reported missing.
        let expectation = try decode("""
        { "items": [ { "name": "milk" }, { "name": "whole" } ] }
        """)
        let problems = expectation.mismatches(in: makeReceipt())
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("missing"))
    }

    func testOverlappingKeywordsFindTheValidAssignment() throws {
        // "milk" matches both parsed items, "whole" matches only "Whole Milk".
        // Greedy first-match would let "milk" grab "Whole Milk" and then
        // spuriously report "whole" missing; the bipartite matcher must find
        // milk → Almond Milk, whole → Whole Milk — in either listing order.
        let receipt = ParsedReceipt(items: [
            ParsedItem(id: .milk, name: "Whole Milk", receiptText: nil,
                       quantity: 1, shelfLifeDays: 7),
            ParsedItem(id: .milk, name: "Almond Milk", receiptText: nil,
                       quantity: 1, shelfLifeDays: 10),
        ])
        for items in [#"[ { "name": "milk" }, { "name": "whole" } ]"#,
                      #"[ { "name": "whole" }, { "name": "milk" } ]"#] {
            let expectation = try decode(#"{ "items": \#(items) }"#)
            XCTAssertEqual(expectation.mismatches(in: receipt), [])
        }
    }
}
