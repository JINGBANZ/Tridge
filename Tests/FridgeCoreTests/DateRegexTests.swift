import XCTest
@testable import FridgeCore

final class DateRegexTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-07-04 10:00 UTC — matches the spec's example label "BEST BY 07/12/26".
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 10))!
    }

    private func assertFound(_ text: String, _ y: Int, _ m: Int, _ d: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let date = DateLabelParser.firstPlausibleDate(in: text, now: now, calendar: calendar) else {
            XCTFail("no date found in \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(calendar.component(.year, from: date), y, file: file, line: line)
        XCTAssertEqual(calendar.component(.month, from: date), m, file: file, line: line)
        XCTAssertEqual(calendar.component(.day, from: date), d, file: file, line: line)
    }

    func testSlashFormats() {
        assertFound("BEST BY 07/12/26", 2026, 7, 12)
        assertFound("USE BY 08/01/2026 LOT 4432", 2026, 8, 1)
        assertFound("EXP 7/9/26", 2026, 7, 9)
    }

    func testMonthNameFormat() {
        assertFound("BEST BEFORE 12 AUG 2026", 2026, 8, 12)
        assertFound("best before 3 September 2026", 2026, 9, 3)
        assertFound("12 AUG. 2026", 2026, 8, 12)
    }

    func testISOFormat() {
        assertFound("2026-08-12 PLANT 22", 2026, 8, 12)
    }

    func testRejectsPastDates() {
        XCTAssertNil(DateLabelParser.firstPlausibleDate(in: "PACKED 06/01/26",
                                                        now: now, calendar: calendar))
        // Today itself is not plausible — the label must be a future date.
        XCTAssertNil(DateLabelParser.firstPlausibleDate(in: "07/04/26",
                                                        now: now, calendar: calendar))
    }

    func testRejectsFarFutureDates() {
        XCTAssertNil(DateLabelParser.firstPlausibleDate(in: "SERIAL 01/01/2099",
                                                        now: now, calendar: calendar))
    }

    func testRejectsImpossibleCalendarDates() {
        XCTAssertNil(DateLabelParser.firstPlausibleDate(in: "02/30/27",
                                                        now: now, calendar: calendar))
    }

    func testSkipsImplausibleAndTakesFirstPlausible() {
        // Packed date (past) is printed before the best-by date.
        assertFound("PKD 06/28/26 BEST BY 07/12/26", 2026, 7, 12)
    }

    func testNoDateReturnsNil() {
        XCTAssertNil(DateLabelParser.firstPlausibleDate(in: "NET WT 16 OZ LOT 12345",
                                                        now: now, calendar: calendar))
    }
}
