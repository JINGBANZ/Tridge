import XCTest
@testable import FridgeCore

final class InventoryDayTests: XCTestCase {
    private func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    func testEpochDayIsOrdinalZero() {
        XCTAssertEqual(InventoryDay(year: 1970, month: 1, day: 1)?.ordinal, 0)
    }

    func testKnownOrdinals() {
        // Independently produced by Python's `date(y, m, d) - date(1970, 1, 1)`.
        XCTAssertEqual(InventoryDay(year: 2000, month: 1, day: 1)?.ordinal, 10_957)
        XCTAssertEqual(InventoryDay(year: 2026, month: 8, day: 18)?.ordinal, 20_683)
        XCTAssertEqual(InventoryDay(year: 2024, month: 2, day: 29)?.ordinal, 19_782)
        XCTAssertEqual(InventoryDay(year: 1969, month: 12, day: 31)?.ordinal, -1)
        XCTAssertEqual(InventoryDay(year: 1900, month: 1, day: 1)?.ordinal, -25_567)
    }

    func testOrdinalRoundTripsAcrossTheSupportedRange() {
        for ordinal in stride(from: -719_162, through: 2_932_896, by: 7_919) {
            let day = InventoryDay(ordinal: Int32(ordinal))
            XCTAssertNotNil(day, "ordinal \(ordinal) should be supported")
            guard let day else { continue }
            let civil = day.components
            XCTAssertEqual(InventoryDay(year: civil.year, month: civil.month, day: civil.day),
                           day)
        }
    }

    func testSupportedRangeBounds() {
        XCTAssertEqual(InventoryDay.earliest.ordinal, -719_162)
        XCTAssertEqual(InventoryDay.latest.ordinal, 2_932_896)
        XCTAssertNil(InventoryDay(ordinal: InventoryDay.earliest.ordinal - 1))
        XCTAssertNil(InventoryDay(ordinal: InventoryDay.latest.ordinal + 1))
    }

    func testRejectsDatesThatDoNotExist() {
        XCTAssertNil(InventoryDay(year: 2026, month: 2, day: 30))
        XCTAssertNil(InventoryDay(year: 2026, month: 13, day: 1))
        XCTAssertNil(InventoryDay(year: 2026, month: 0, day: 1))
        XCTAssertNil(InventoryDay(year: 2026, month: 4, day: 31))
        XCTAssertNil(InventoryDay(year: 2025, month: 2, day: 29))  // not a leap year
        XCTAssertNil(InventoryDay(year: 0, month: 1, day: 1))
    }

    func testCivilDayDoesNotChangeAcrossTimeZones() {
        // The stored ordinal is the contract: rendering it anywhere on earth
        // must show the same calendar date (ADR 0003).
        let expiry = InventoryDay(year: 2026, month: 8, day: 18)!
        for zone in ["UTC", "Asia/Tokyo", "Pacific/Honolulu", "Pacific/Kiritimati"] {
            let rendered = expiry.startOfDay(in: calendar(zone))
            XCTAssertNotNil(rendered)
            XCTAssertEqual(InventoryDay(date: rendered!, calendar: calendar(zone)), expiry)
            XCTAssertEqual(expiry.components.day, 18)
        }
    }

    func testDayOfAnInstantFollowsTheViewersTimeZone() {
        // 2026-08-18T23:30Z is already the 19th in Tokyo — capturing "today"
        // is the one conversion that legitimately depends on the viewer.
        let instant = Date(timeIntervalSince1970: 20_683 * 86_400 + 23 * 3_600 + 1_800)
        XCTAssertEqual(InventoryDay(date: instant, calendar: calendar("UTC")),
                       InventoryDay(year: 2026, month: 8, day: 18))
        XCTAssertEqual(InventoryDay(date: instant, calendar: calendar("Asia/Tokyo")),
                       InventoryDay(year: 2026, month: 8, day: 19))
    }

    func testGregorianReckoningIsPinnedForNonGregorianCalendars() {
        // A device set to the Buddhist calendar reports year 2569; the stored
        // ordinal must stay Gregorian so members agree on the date.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        let instant = Date(timeIntervalSince1970: 20_683 * 86_400)
        XCTAssertEqual(InventoryDay(date: instant, calendar: buddhist),
                       InventoryDay(year: 2026, month: 8, day: 18))
    }

    func testTodayFollowsTheViewersTimeZone() {
        let instant = Date(timeIntervalSince1970: 20_683 * 86_400 + 23 * 3_600 + 1_800)
        XCTAssertEqual(InventoryDay.today(in: calendar("UTC"), now: instant),
                       InventoryDay(year: 2026, month: 8, day: 18))
        XCTAssertEqual(InventoryDay.today(in: calendar("Asia/Tokyo"), now: instant),
                       InventoryDay(year: 2026, month: 8, day: 19))
    }

    func testDayArithmetic() {
        let day = InventoryDay(year: 2026, month: 3, day: 1)!
        XCTAssertEqual(day.adding(days: -1), InventoryDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(day.adding(days: 365), InventoryDay(year: 2027, month: 3, day: 1))
        XCTAssertEqual(InventoryDay(year: 2026, month: 3, day: 4)!.days(since: day), 3)
        XCTAssertEqual(day.days(since: InventoryDay(year: 2026, month: 3, day: 4)!), -3)
        XCTAssertNil(InventoryDay.latest.adding(days: 1))
        XCTAssertNil(InventoryDay.earliest.adding(days: -1))
    }

    func testCodableRoundTripsTheBareOrdinal() throws {
        let day = InventoryDay(year: 2026, month: 8, day: 18)!
        let encoded = try JSONEncoder().encode(day)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "20683")
        XCTAssertEqual(try JSONDecoder().decode(InventoryDay.self, from: encoded), day)
    }

    func testDecodingRejectsAnUnsupportedOrdinal() {
        let encoded = Data("2932897".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InventoryDay.self, from: encoded))
    }
}
