import XCTest
@testable import FridgeCore

final class UrgencyLogicTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-07-04 10:00 UTC
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 10))!
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testDaysLeftCountsCalendarDaysNotHours() {
        // 23:59 today is still 0 days left even though < 24h away.
        XCTAssertEqual(UrgencyRules.daysLeft(until: date(2026, 7, 4, hour: 23),
                                             from: now, calendar: calendar), 0)
        XCTAssertEqual(UrgencyRules.daysLeft(until: date(2026, 7, 5, hour: 0),
                                             from: now, calendar: calendar), 1)
        XCTAssertEqual(UrgencyRules.daysLeft(until: date(2026, 7, 16),
                                             from: now, calendar: calendar), 12)
        XCTAssertEqual(UrgencyRules.daysLeft(until: date(2026, 7, 3),
                                             from: now, calendar: calendar), -1)
    }

    func testUrgencyThresholds() {
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: 3), .fresh)
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: 30), .fresh)
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: 2), .soon)
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: 1), .soon)
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: 0), .today)
        XCTAssertEqual(UrgencyRules.urgency(daysLeft: -1), .expired)
    }

    func testExpiredMeansEndOfExpiryDayHasPassed() {
        // Expiry day is today: not expired yet, even late in the day.
        let lateToday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 23, minute: 50))!
        XCTAssertFalse(UrgencyRules.isExpired(expiry: date(2026, 7, 4, hour: 9),
                                              now: lateToday, calendar: calendar))
        // Expired the moment the next day starts.
        let nextMidnight = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 0, minute: 1))!
        XCTAssertTrue(UrgencyRules.isExpired(expiry: date(2026, 7, 4, hour: 9),
                                             now: nextMidnight, calendar: calendar))
    }

    func testPillLabels() {
        XCTAssertEqual(UrgencyRules.pillLabel(daysLeft: 12), "12d")
        XCTAssertEqual(UrgencyRules.pillLabel(daysLeft: 1), "1d")
        XCTAssertEqual(UrgencyRules.pillLabel(daysLeft: 0), "Today")
        XCTAssertEqual(UrgencyRules.pillLabel(daysLeft: -1), "✕ 1d")
        XCTAssertEqual(UrgencyRules.pillLabel(daysLeft: -14), "✕ 14d")
    }

    func testSpokenFreshness() {
        XCTAssertEqual(UrgencyRules.spokenFreshness(daysLeft: 12), "expires in 12 days")
        XCTAssertEqual(UrgencyRules.spokenFreshness(daysLeft: 0), "expires today")
        XCTAssertEqual(UrgencyRules.spokenFreshness(daysLeft: -3), "expired 3 days ago")
    }
}
