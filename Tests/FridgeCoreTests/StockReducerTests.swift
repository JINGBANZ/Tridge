import XCTest
@testable import FridgeCore

final class StockReducerTests: XCTestCase {
    /// Deterministic ids so byte-order tie-breaks are reproducible.
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    private func event(_ seed: UInt8, _ delta: Int64, _ reason: StockReason,
                       at instant: TimeInterval = 0) -> StockEvent {
        StockEvent(id: id(seed), delta: delta, reason: reason,
                   occurredAt: Date(timeIntervalSince1970: instant))
    }

    func testSumsOperationsIndependentlyOfInputOrder() {
        let events = [event(1, 5, .acquired), event(2, -1, .eaten), event(3, 2, .adjusted)]
        let forward = StockReducer.reduce(events)
        let reversed = StockReducer.reduce(events.reversed())
        let shuffled = StockReducer.reduce([events[2], events[0], events[1]])

        XCTAssertEqual(forward.quantity, 6)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, shuffled)
    }
}

extension StockReducerTests {
    func testEmptyHistoryProjectsNothing() {
        let projection = StockReducer.reduce([])
        XCTAssertEqual(projection.quantity, 0)
        XCTAssertFalse(projection.isDeleted)
        XCTAssertFalse(projection.isVisible)
        XCTAssertTrue(projection.issues.isEmpty)
    }

    func testIdenticalRetryAppliesOnce() {
        // A retried command reuses its id, so replaying it must not double-count.
        let retried = event(1, 3, .acquired)
        let projection = StockReducer.reduce([retried, retried, retried])
        XCTAssertEqual(projection.quantity, 3)
        XCTAssertTrue(projection.issues.isEmpty)
    }

    func testConflictingDuplicateIdIsResolvedDeterministically() {
        // Corrupt data only: the same id must never reduce to different totals
        // on two devices.
        let earlier = event(1, 4, .acquired, at: 100)
        let later = event(1, 9, .acquired, at: 500)
        let forward = StockReducer.reduce([earlier, later])
        let reversed = StockReducer.reduce([later, earlier])

        XCTAssertEqual(forward.quantity, 4)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.issues, [.conflictingDuplicate(id(1))])
    }

    func testConflictingDuplicateBreaksTiesOnDeltaThenReason() {
        let low = event(1, -1, .eaten, at: 100)
        let high = event(1, -1, .tossed, at: 100)
        XCTAssertEqual(StockReducer.reduce([high, low]).issues, [.conflictingDuplicate(id(1))])
        // "eaten" < "tossed" once occurredAt and delta tie.
        XCTAssertEqual(StockReducer.reduce([high, low]).quantity, 0)
        XCTAssertEqual(StockReducer.reduce([event(9, 5, .acquired), high, low]).quantity, 4)
    }

    func testConcurrentAddAndConsumeBothSurvive() {
        // Two offline members: one buys two, the other eats one.
        let projection = StockReducer.reduce([
            event(1, 1, .acquired), event(2, 2, .acquired), event(3, -1, .eaten),
        ])
        XCTAssertEqual(projection.quantity, 2)
        XCTAssertTrue(projection.isVisible)
    }

    func testQuantityNeverDisplaysNegativeButRawSumIsKept() {
        // Two peers each consume the last visible unit.
        let projection = StockReducer.reduce([
            event(1, 1, .acquired), event(2, -1, .eaten), event(3, -1, .eaten),
        ])
        XCTAssertEqual(projection.quantity, 0)
        XCTAssertEqual(projection.rawQuantity, -1)
        XCTAssertFalse(projection.isVisible)
    }

    func testZeroIsRevivedByADelayedValidOperation() {
        let depleted = [event(1, 1, .acquired), event(2, -1, .eaten)]
        XCTAssertEqual(StockReducer.reduce(depleted).quantity, 0)
        XCTAssertFalse(StockReducer.reduce(depleted).isVisible)

        // The offline member's purchase finally imports (ADR 0010).
        let revived = StockReducer.reduce(depleted + [event(3, 2, .acquired)])
        XCTAssertEqual(revived.quantity, 2)
        XCTAssertTrue(revived.isVisible)
    }

    func testDeleteIsTerminalEvenWhenStockArrivesAfterwards() {
        let deleted = [event(1, 4, .acquired), event(2, 0, .deleted)]
        XCTAssertTrue(StockReducer.reduce(deleted).isDeleted)
        XCTAssertFalse(StockReducer.reduce(deleted).isVisible)

        let late = StockReducer.reduce(deleted + [event(3, 3, .acquired)])
        XCTAssertTrue(late.isDeleted)
        XCTAssertEqual(late.quantity, 7, "history stays complete; the group is just closed")
        XCTAssertFalse(late.isVisible)
    }

    func testAdjustmentCommitsTheDifferenceNotTheTarget() {
        // Quantity field set to 5 while the local projection showed 2, and a
        // remote purchase of 3 that the editor never saw lands as well.
        let projection = StockReducer.reduce([
            event(1, 2, .acquired), event(2, 3, .adjusted), event(3, 3, .acquired),
        ])
        XCTAssertEqual(projection.quantity, 8)
    }

    func testPreservedStockFromStopSharingCounts() {
        XCTAssertEqual(StockReducer.reduce([event(1, 6, .preserved)]).quantity, 6)
    }

    func testAcceptsEveryPositiveWholeNumberWithNoProductCap() {
        // ADR 0004: no 99-unit cap.
        let bulk = StockReducer.reduce([event(1, 5_000, .acquired), event(2, 250_000, .acquired)])
        XCTAssertEqual(bulk.quantity, 255_000)
    }

    func testOverflowMarksTheItemCorruptInsteadOfWrapping() {
        let projection = StockReducer.reduce([
            event(1, .max, .acquired), event(2, 1, .acquired),
        ])
        XCTAssertTrue(projection.isCorrupt)
        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.quantity, 0)
        XCTAssertTrue(projection.issues.contains(.quantityOverflow))
    }

    func testOverflowDetectionIsOrderIndependent() {
        // Summing follows canonical id order, so whether an intermediate
        // overflows cannot depend on the order the records were imported in.
        let events = [event(1, .max, .acquired), event(2, 1, .acquired),
                      event(3, -1, .eaten)]
        XCTAssertEqual(StockReducer.reduce(events), StockReducer.reduce(events.reversed()))
        XCTAssertTrue(StockReducer.reduce(events.reversed()).isCorrupt)
    }

    func testAnOrderThatWouldOverflowOnlyOutsideCanonicalOrderStillReduces() {
        // max, then -1, then +1 is safe in canonical order — and canonical
        // order is what every device uses.
        let events = [event(1, .max, .acquired), event(2, -1, .eaten), event(3, 1, .acquired)]
        let projection = StockReducer.reduce(events.reversed())
        XCTAssertFalse(projection.isCorrupt)
        XCTAssertEqual(projection.quantity, .max)
    }

    func testMalformedEventsAreDroppedWithoutHidingValidStock() {
        let projection = StockReducer.reduce([
            event(1, 4, .acquired),
            event(2, -2, .eaten),       // eaten is exactly -1
            event(3, 0, .adjusted),     // zero for a nonterminal reason
            event(4, 5, .deleted),      // the terminal marker carries no delta
            event(5, -1, .acquired),    // a purchase cannot be negative
        ])
        XCTAssertEqual(projection.quantity, 4)
        XCTAssertFalse(projection.isDeleted, "a malformed delete cannot close the item")
        XCTAssertEqual(projection.issues, [.malformedEvent(id(2)), .malformedEvent(id(3)),
                                           .malformedEvent(id(4)), .malformedEvent(id(5))])
    }

    func testNonfiniteInstantIsMalformed() {
        let broken = StockEvent(id: id(1), delta: 2, reason: .acquired,
                                occurredAt: Date(timeIntervalSince1970: .nan))
        let projection = StockReducer.reduce([broken, event(2, 1, .acquired)])
        XCTAssertEqual(projection.quantity, 1)
        XCTAssertEqual(projection.issues, [.malformedEvent(id(1))])
    }

    func testDiagnosticsCarryOnlyIdsAndCategories() {
        // Guards the privacy rule: no names, quantities, or household context.
        let projection = StockReducer.reduce([event(1, -3, .tossed)])
        XCTAssertEqual(projection.issues, [.malformedEvent(id(1))])
    }
}
