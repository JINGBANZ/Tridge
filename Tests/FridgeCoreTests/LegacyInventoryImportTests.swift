import XCTest
@testable import FridgeCore

/// The archive → purchase mapping that decides what an upgrading installation
/// keeps. Every rejection here fails the whole migration rather than writing a
/// partial inventory, so each rule is pinned.
final class LegacyInventoryPlannerTests: XCTestCase {
    /// A fixed offset zone, so the expected civil days do not depend on where
    /// the test runs.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 2026-08-19 00:00 UTC.
    private let purchaseInstant = Date(timeIntervalSince1970: 1_787_097_600)

    private func row(id: UUID = UUID(),
                     name: String = "Whole Milk",
                     artKey: String = ItemID.milk.rawValue,
                     quantity: Int = 2,
                     storageRaw: String = StorageLocation.fridge.rawValue,
                     purchaseDate: Date? = nil,
                     expiryDate: Date? = nil,
                     expirySourceRaw: String = ExpirySource.userSet.rawValue)
    -> LegacyInventoryRow {
        LegacyInventoryRow(id: id, name: name, artKey: artKey, quantity: quantity,
                           storageRaw: storageRaw,
                           purchaseDate: purchaseDate ?? purchaseInstant,
                           expiryDate: expiryDate ?? purchaseInstant.addingTimeInterval(7 * 86_400),
                           expirySourceRaw: expirySourceRaw)
    }

    private func assertCorrupt(_ category: RecordIntegrityIssue.Category,
                               _ rows: [LegacyInventoryRow],
                               line: UInt = #line) {
        XCTAssertThrowsError(try LegacyInventoryPlanner.plan(rows, calendar: calendar),
                             line: line) { error in
            XCTAssertEqual((error as? RecordIntegrityIssue)?.category, category, line: line)
            XCTAssertEqual((error as? RecordIntegrityIssue)?.entity, .item, line: line)
        }
    }

    func testAnActiveRowBecomesOnePurchaseCarryingItsMetadata() throws {
        let id = UUID()
        let drafts = try LegacyInventoryPlanner.plan(
            [row(id: id, storageRaw: StorageLocation.freezer.rawValue)], calendar: calendar)

        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(draft.name, "Whole Milk")
        XCTAssertEqual(draft.normalizedName, "whole milk")
        XCTAssertEqual(draft.quantity, 2)
        XCTAssertEqual(draft.artKey, ItemID.milk.rawValue)
        XCTAssertEqual(draft.storage, .freezer)
        XCTAssertEqual(draft.expirySource, .userSet)
        XCTAssertEqual(draft.purchaseDay, InventoryDay(year: 2026, month: 8, day: 19))
        XCTAssertEqual(draft.expiryDay, InventoryDay(year: 2026, month: 8, day: 26))
        // Nothing here is a user edit: the values are what the row already had.
        XCTAssertTrue(draft.explicitMetadataFields.isEmpty)
    }

    /// The legacy row id is the migration's stable command id, so a retry
    /// recognizes the row it already wrote instead of adding it twice.
    func testTheLegacyIdentityIsReusedForTheRootAndItsAcquisition() throws {
        let id = UUID()

        let draft = try XCTUnwrap(LegacyInventoryPlanner.plan([row(id: id)],
                                                              calendar: calendar).first)

        XCTAssertEqual(draft.itemID, id)
        XCTAssertEqual(draft.stockChangeID, id)
        XCTAssertEqual(draft.acquisition,
                       StockEvent(id: id, delta: 2, reason: .acquired,
                                  occurredAt: draft.occurredAt))
        XCTAssertTrue(draft.acquisition.isWellFormed)
    }

    /// A replan must produce a byte-identical event, or the repository would
    /// read the retry as a conflicting payload for the same command id.
    func testReplanningProducesAnIdenticalAcquisition() throws {
        let rows = [row(), row()]

        let first = try LegacyInventoryPlanner.plan(rows, calendar: calendar)
        let second = try LegacyInventoryPlanner.plan(rows, calendar: calendar)

        XCTAssertEqual(first, second)
    }

    /// One captured calendar converts every row, so a migration running across
    /// local midnight cannot land two rows of one archive on different days.
    func testEveryRowConvertsInTheSuppliedTimeZone() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(secondsFromGMT: -5 * 3_600)!
        // 2026-08-19 02:00 UTC is still 2026-08-18 in that zone.
        let instant = purchaseInstant.addingTimeInterval(2 * 3_600)

        let drafts = try LegacyInventoryPlanner.plan(
            [row(purchaseDate: instant, expiryDate: instant)], calendar: eastern)

        XCTAssertEqual(drafts.first?.purchaseDay, InventoryDay(year: 2026, month: 8, day: 18))
        XCTAssertEqual(drafts.first?.expiryDay, InventoryDay(year: 2026, month: 8, day: 18))
    }

    func testAnUnrecognizedArtKeyIsKeptRatherThanRejected() throws {
        let drafts = try LegacyInventoryPlanner.plan([row(artKey: "future_vocabulary_id")],
                                                     calendar: calendar)

        XCTAssertEqual(drafts.first?.artKey, "future_vocabulary_id")
    }

    func testARowWithNoUsableNameIsCorrupt() {
        assertCorrupt(.invalidName, [row(name: "   ")])
    }

    /// The shipping build flips status to eaten/tossed at the last unit, so an
    /// active row can only carry a positive quantity.
    func testANonPositiveQuantityIsCorrupt() {
        assertCorrupt(.invalidDelta, [row(quantity: 0)])
        assertCorrupt(.invalidDelta, [row(quantity: -1)])
    }

    func testAnUnrepresentableStorageOrExpirySourceIsCorrupt() {
        assertCorrupt(.invalidRawValue, [row(storageRaw: "cupboard")])
        assertCorrupt(.invalidRawValue, [row(expirySourceRaw: "guessed")])
    }

    func testANonFiniteInstantIsCorrupt() {
        assertCorrupt(.invalidInstant, [row(purchaseDate: Date(timeIntervalSince1970: .nan))])
        assertCorrupt(.invalidInstant, [row(expiryDate: Date(timeIntervalSince1970: .infinity))])
    }

    /// The shipping build derived expiry from an unbounded `shelf_life_days`
    /// with no clamp, so a hallucinated shelf life really can sit past the
    /// supported range. Clamping keeps the row — failing it would leave that
    /// installation unable to migrate anything, ever.
    func testAnExpiryPastTheSupportedRangeIsClampedRatherThanRejected() throws {
        // Year 10000, one day past the supported range.
        let farFuture = Date(timeIntervalSince1970: 253_402_300_800)

        let drafts = try LegacyInventoryPlanner.plan([row(expiryDate: farFuture)],
                                                     calendar: calendar)

        XCTAssertEqual(drafts.first?.expiryDay, .latest)
        XCTAssertEqual(drafts.first?.purchaseDay, InventoryDay(year: 2026, month: 8, day: 19))
    }

    /// A purchase day cannot come from a model guess — the shipping build
    /// stamped it with `Date()` — so an unrepresentable one is corrupt data.
    func testAPurchaseDayOutsideTheSupportedRangeIsCorrupt() {
        let farFuture = Date(timeIntervalSince1970: 253_402_300_800)
        assertCorrupt(.invalidDay, [row(purchaseDate: farFuture)])
    }

    /// Two rows claiming one identity would write two records under one id.
    func testTwoRowsSharingAnIdentityAreCorrupt() {
        let id = UUID()
        assertCorrupt(.duplicateIdentity, [row(id: id), row(id: id, name: "Eggs")])
    }

    func testAnEmptyArchivePlansNothing() throws {
        XCTAssertTrue(try LegacyInventoryPlanner.plan([], calendar: calendar).isEmpty)
    }

    /// The first unmappable row stops the plan: nothing is written unless the
    /// whole set maps.
    func testOneCorruptRowFailsThePlanForEveryRow() {
        assertCorrupt(.invalidName, [row(), row(name: ""), row()])
    }
}
