import Foundation

/// Freshness state driving the status pill (see spec → "Design tokens").
/// `today` and `expired` both render red; they differ in label and art treatment.
public enum Urgency: Equatable, Sendable {
    case fresh   // ≥ 3 days left
    case soon    // 1–2 days left
    case today   // expires today
    case expired // past end-of-day of expiryDate
}

public enum UrgencyRules {
    /// Whole calendar days from `now`'s day to `expiry`'s day (negative when past).
    public static func daysLeft(until expiry: Date, from now: Date = Date(),
                                calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    public static func urgency(daysLeft: Int) -> Urgency {
        switch daysLeft {
        case ..<0: .expired
        case 0: .today
        case 1...2: .soon
        default: .fresh
        }
    }

    /// Expired means end-of-day(expiryDate) < now, i.e. the expiry day is over.
    public static func isExpired(expiry: Date, now: Date = Date(),
                                 calendar: Calendar = .current) -> Bool {
        daysLeft(until: expiry, from: now, calendar: calendar) < 0
    }

    /// Pill label: "Nd" / "Today" / "✕ Nd" (days since expiry).
    public static func pillLabel(daysLeft: Int) -> String {
        switch urgency(daysLeft: daysLeft) {
        case .fresh, .soon: "\(daysLeft)d"
        case .today: "Today"
        case .expired: "✕ \(-daysLeft)d"
        }
    }
}
