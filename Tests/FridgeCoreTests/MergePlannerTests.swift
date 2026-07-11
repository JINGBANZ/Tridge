import XCTest
@testable import FridgeCore

final class MergePlannerTests: XCTestCase {
    private func candidate(_ name: String, quantity: Int = 1, expired: Bool = false,
                           purchasedDaysAgo: Int = 0, id: UUID = UUID()) -> MergeCandidate {
        MergeCandidate(id: id,
                       normalizedName: NameKey.normalize(name),
                       quantity: quantity,
                       isExpired: expired,
                       purchaseDate: Date(timeIntervalSinceNow: -Double(purchasedDaysAgo) * 86_400))
    }

    func testExactNormalizedMatchMerges() {
        let milk = candidate("Milk", quantity: 2)
        let decision = MergePlanner.decide(name: "  MILK ", quantity: 1, existing: [milk])
        XCTAssertEqual(decision, .merge(into: milk.id, resultingQuantity: 3))
    }

    func testDiacriticInsensitiveMatch() {
        let peppers = candidate("Jalapeño Peppers", quantity: 2)
        let decision = MergePlanner.decide(name: "jalapeno peppers", quantity: 1,
                                           existing: [peppers])
        XCTAssertEqual(decision, .merge(into: peppers.id, resultingQuantity: 3))
    }

    func testNoMatchInserts() {
        let decision = MergePlanner.decide(name: "Butter", quantity: 1,
                                           existing: [candidate("Milk")])
        XCTAssertEqual(decision, .insert)
    }

    func testDifferentNamesNeverMerge() {
        // Close spelling is not identity: exact normalized match only.
        let decision = MergePlanner.decide(name: "Milkshake", quantity: 1,
                                           existing: [candidate("Milk")])
        XCTAssertEqual(decision, .insert)
    }

    func testExpiredCandidateIsSkipped() {
        // A fresh purchase of something already expired is a new batch.
        let decision = MergePlanner.decide(name: "Milk", quantity: 1,
                                           existing: [candidate("Milk", expired: true)])
        XCTAssertEqual(decision, .insert)
    }

    func testMostRecentPurchaseWinsAmongMatches() {
        let older = candidate("Milk", quantity: 1, purchasedDaysAgo: 10)
        let newer = candidate("Milk", quantity: 2, purchasedDaysAgo: 1)
        let decision = MergePlanner.decide(name: "Milk", quantity: 1,
                                           existing: [older, newer])
        XCTAssertEqual(decision, .merge(into: newer.id, resultingQuantity: 3))
    }

    func testQuantityClampsAt99() {
        let bulk = candidate("Rice", quantity: 98)
        let decision = MergePlanner.decide(name: "Rice", quantity: 5, existing: [bulk])
        XCTAssertEqual(decision, .merge(into: bulk.id, resultingQuantity: 99))
    }

    func testEmptyNameAlwaysInserts() {
        let decision = MergePlanner.decide(name: "   ", quantity: 1,
                                           existing: [candidate("")])
        XCTAssertEqual(decision, .insert)
    }

    // MARK: Multi-row plans (the scan confirm)

    func testPlanRoutesRowsIndependently() {
        let milk = candidate("Milk", quantity: 1)
        let plans = MergePlanner.plan(rows: [("Milk", 1), ("Eggs", 2)],
                                      existing: [milk])
        XCTAssertEqual(plans, [.merge(.existing(milk.id), resultingQuantity: 2),
                               .insert])
    }

    func testRenameCollisionStacksOntoTheInsertedRow() {
        // Two review rows renamed to the same new name: the second must stack
        // onto the first row's insert, never vanish or duplicate.
        let plans = MergePlanner.plan(rows: [("Milk", 1), ("Milk", 2)],
                                      existing: [])
        XCTAssertEqual(plans, [.insert,
                               .merge(.insertedRow(0), resultingQuantity: 3)])
    }

    func testThreeWayCollisionKeepsAccumulating() {
        let plans = MergePlanner.plan(rows: [("Milk", 1), ("milk", 1), ("MILK ", 1)],
                                      existing: [])
        XCTAssertEqual(plans, [.insert,
                               .merge(.insertedRow(0), resultingQuantity: 2),
                               .merge(.insertedRow(0), resultingQuantity: 3)])
    }

    func testRepeatedMergesIntoOneExistingItemAccumulate() {
        let milk = candidate("Milk", quantity: 1)
        let plans = MergePlanner.plan(rows: [("Milk", 1), ("Milk", 1)],
                                      existing: [milk])
        XCTAssertEqual(plans, [.merge(.existing(milk.id), resultingQuantity: 2),
                               .merge(.existing(milk.id), resultingQuantity: 3)])
    }

    func testPlanSkipsExpiredExistingAndStacksInserts() {
        let expired = candidate("Milk", quantity: 5, expired: true)
        let plans = MergePlanner.plan(rows: [("Milk", 1), ("Milk", 1)],
                                      existing: [expired])
        XCTAssertEqual(plans, [.insert,
                               .merge(.insertedRow(0), resultingQuantity: 2)])
    }

    func testEmptyNamedRowsNeverStackOnEachOther() {
        let plans = MergePlanner.plan(rows: [("", 1), ("", 1)], existing: [])
        XCTAssertEqual(plans, [.insert, .insert])
    }
}
