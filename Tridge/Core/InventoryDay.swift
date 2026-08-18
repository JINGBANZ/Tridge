import Foundation

/// A timezone-independent Gregorian calendar date — the type behind Purchase Day
/// and Expiry Day (see wiki/adr/0003-model-inventory-dates-as-civil-days.md).
///
/// Two household members in different time zones must see the same expiry date
/// for the same item, so the persisted value is a signed day ordinal relative to
/// 1970-01-01 computed from calendar components. It is deliberately never derived
/// by dividing an absolute instant by 86,400: that reintroduces the time zone the
/// ordinal exists to remove. Creation, modification, and stock-event occurrence
/// stay absolute instants.
public struct InventoryDay: Hashable, Comparable, Sendable {
    /// Days since 1970-01-01 in the proleptic Gregorian calendar. Negative before it.
    public let ordinal: Int32

    /// Supported civil range, chosen so every ordinal round-trips through
    /// `components` and fits `Int32` (the persisted attribute width).
    public static let minimumYear = 1
    public static let maximumYear = 9999
    public static let earliest = InventoryDay(uncheckedOrdinal: Self.daysFromCivil(year: minimumYear, month: 1, day: 1))
    public static let latest = InventoryDay(uncheckedOrdinal: Self.daysFromCivil(year: maximumYear, month: 12, day: 31))

    private init(uncheckedOrdinal ordinal: Int) {
        self.ordinal = Int32(ordinal)
    }

    /// Validates an imported/persisted ordinal. Out-of-range values are corrupt
    /// data and must never reach a snapshot.
    public init?(ordinal: Int32) {
        guard ordinal >= Self.earliest.ordinal, ordinal <= Self.latest.ordinal else { return nil }
        self.ordinal = ordinal
    }

    /// Fails for a date that does not exist (month 13, 30 February, year 0).
    public init?(year: Int, month: Int, day: Int) {
        guard year >= Self.minimumYear, year <= Self.maximumYear,
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let ordinal = Self.daysFromCivil(year: year, month: month, day: day)
        // Round-trip rejects the days that overflow their month (2026-02-30
        // would otherwise silently land on 2 March).
        let civil = Self.civilFromDays(ordinal)
        guard civil.year == year, civil.month == month, civil.day == day else { return nil }
        self.init(ordinal: Int32(ordinal))
    }

    /// The civil day `date` falls on for a viewer in `calendar`'s time zone.
    /// The Gregorian reckoning is pinned: the ordinal must not shift if the
    /// device is set to a non-Gregorian calendar.
    public init?(date: Date, calendar: Calendar) {
        let parts = Self.gregorian(matching: calendar)
            .dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var components: (year: Int, month: Int, day: Int) {
        Self.civilFromDays(Int(ordinal))
    }

    /// The instant this civil day begins for a viewer in `calendar`'s time zone —
    /// the only place an absolute instant is derived, for display and reminders.
    public func startOfDay(in calendar: Calendar) -> Date? {
        let civil = components
        var parts = DateComponents()
        parts.year = civil.year
        parts.month = civil.month
        parts.day = civil.day
        return Self.gregorian(matching: calendar).date(from: parts)
    }

    /// Whole days from `other` to `self`; negative when `self` is earlier.
    public func days(since other: InventoryDay) -> Int {
        Int(ordinal) - Int(other.ordinal)
    }

    /// Nil when the shift leaves the supported civil range.
    public func adding(days: Int) -> InventoryDay? {
        let shifted = Int(ordinal) + days
        guard let narrowed = Int32(exactly: shifted) else { return nil }
        return InventoryDay(ordinal: narrowed)
    }

    public static func < (lhs: InventoryDay, rhs: InventoryDay) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    private static func gregorian(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        return gregorian
    }

    // Howard Hinnant's `days_from_civil`/`civil_from_days` (chrono-Compatible
    // Low-Level Date Algorithms), which are exact for the proleptic Gregorian
    // calendar and need no Foundation calendar at all.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                        // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ ordinal: Int) -> (year: Int, month: Int, day: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097                                     // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // [0, 365]
        let monthPrime = (5 * dayOfYear + 2) / 153                           // [0, 11]
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1                 // [1, 31]
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)                  // [1, 12]
        return (year + (month <= 2 ? 1 : 0), month, day)
    }
}

extension InventoryDay: Codable {
    /// Encoded as its bare ordinal so the JSON export and the persisted
    /// attribute carry the same value.
    public init(from decoder: Decoder) throws {
        let ordinal = try decoder.singleValueContainer().decode(Int32.self)
        guard let day = InventoryDay(ordinal: ordinal) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Inventory day ordinal out of supported range"))
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ordinal)
    }
}
