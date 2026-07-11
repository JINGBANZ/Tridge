import Foundation

/// One searchable name with the signals used for ranking ties.
public struct SearchEntry: Equatable, Sendable {
    public let normalizedName: String
    /// Most recent purchase of this name.
    public let lastUsed: Date
    /// How many times this name has been added.
    public let useCount: Int

    public init(normalizedName: String, lastUsed: Date, useCount: Int) {
        self.normalizedName = normalizedName
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

/// In-memory ranking for inventory lookup and the manual-add suggestion
/// chips. The dataset is tens-to-hundreds of short strings, so a linear scan
/// per keystroke is sub-millisecond — no index or FTS machinery needed.
public enum NameSearch {
    /// Match tier, best first: exact, whole-string prefix, word-boundary
    /// prefix ("mi" → "whole milk"), substring. `nil` means no match.
    /// Query and candidate are both expected in `NameKey.normalize` form.
    public static func tier(query: String, candidate: String) -> Int? {
        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 1 }
        if candidate.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(query) }) {
            return 2
        }
        if candidate.contains(query) { return 3 }
        return nil
    }

    /// Top matches for a query; an empty query returns the most recent
    /// entries (the pre-typing chips). Ties break by recency, then frequency,
    /// then name for determinism.
    public static func rank(query: String, in entries: [SearchEntry],
                            limit: Int) -> [SearchEntry] {
        let key = NameKey.normalize(query)
        let scored: [(SearchEntry, Int)]
        if key.isEmpty {
            scored = entries.map { ($0, 0) }
        } else {
            scored = entries.compactMap { entry in
                tier(query: key, candidate: entry.normalizedName).map { (entry, $0) }
            }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.lastUsed != rhs.0.lastUsed { return lhs.0.lastUsed > rhs.0.lastUsed }
                if lhs.0.useCount != rhs.0.useCount { return lhs.0.useCount > rhs.0.useCount }
                return lhs.0.normalizedName < rhs.0.normalizedName
            }
            .prefix(limit)
            .map(\.0)
    }
}
