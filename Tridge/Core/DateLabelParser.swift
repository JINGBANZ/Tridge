import Foundation

/// Finds a printed expiry date ("BEST BY 07/12/26", "12 AUG 2026", "2026-08-12")
/// in OCR output. Formats per spec: MM/DD/YY(YY), DD MMM YYYY, YYYY-MM-DD.
public enum DateLabelParser {
    private static let monthNames: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]

    private struct Candidate {
        var location: Int
        var date: Date
    }

    /// The first (by position in `text`) date that is plausibly a future expiry:
    /// strictly after today and less than five years out.
    public static func firstPlausibleDate(in text: String, now: Date = Date(),
                                          calendar: Calendar = .current) -> Date? {
        candidates(in: text, calendar: calendar)
            .sorted { $0.location < $1.location }
            .first { isPlausible($0.date, now: now, calendar: calendar) }?
            .date
    }

    static func isPlausible(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let cap = calendar.date(byAdding: .year, value: 5, to: now) else { return false }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: now) && date < cap
    }

    private static func candidates(in text: String, calendar: Calendar) -> [Candidate] {
        var found: [Candidate] = []
        let ns = text as NSString

        func scan(_ pattern: String, _ build: ([String]) -> DateComponents?) {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let groups = (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
                if var components = build(groups) {
                    components.hour = 12 // noon avoids DST edge cases around midnight
                    if let date = calendar.date(from: components), matches(date, components, calendar) {
                        found.append(Candidate(location: match.range.location, date: date))
                    }
                }
            }
        }

        // YYYY-MM-DD
        scan(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) { g in
            DateComponents(year: Int(g[0]), month: Int(g[1]), day: Int(g[2]))
        }
        // MM/DD/YY or MM/DD/YYYY
        scan(#"\b(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})\b"#) { g in
            guard var year = Int(g[2]) else { return nil }
            if year < 100 { year += 2000 }
            return DateComponents(year: year, month: Int(g[0]), day: Int(g[1]))
        }
        // DD MMM YYYY (month name possibly spelled out: "12 AUGUST 2026")
        scan(#"\b(\d{1,2})\s+(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\.?\s+(\d{4})\b"#) { g in
            guard let month = monthNames[g[1].uppercased()] else { return nil }
            return DateComponents(year: Int(g[2]), month: month, day: Int(g[0]))
        }
        return found
    }

    /// Rejects roll-over artifacts like 02/30 → Mar 2 that Calendar would accept.
    private static func matches(_ date: Date, _ components: DateComponents,
                                _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: date) == components.year
            && calendar.component(.month, from: date) == components.month
            && calendar.component(.day, from: date) == components.day
    }
}
