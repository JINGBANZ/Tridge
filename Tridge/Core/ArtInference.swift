import Foundation

/// Deterministic name → `ItemID` mapping for names never seen before, so
/// manual add needs no art picker. Resolution tiers (design doc §3.3):
/// exact vocabulary/display-name match → synonym table → per-token match
/// (last matching token wins — the head noun in English) → typo tolerance
/// (edit distance ≤ 1, safe because the art previews live before saving) →
/// `.unknown`. Remembered art (a name the user saved before) is tier 0 and
/// lives with the history lookup in the app, not here.
public enum ArtInference {
    public static func itemID(for name: String) -> ItemID {
        let normalized = NameKey.normalize(name)
        guard !normalized.isEmpty else { return .unknown }

        // Tiers 1–2: the whole name, with naive plural fallbacks
        // ("sweet potatoes" → "sweet potato").
        for candidate in singularCandidates(normalized) {
            if let id = lookup[candidate] { return id }
        }

        // Tier 3: single tokens, head noun (last token) first
        // ("chocolate milk" → milk).
        let tokens = normalized.split(separator: " ").map(String.init)
        if tokens.count > 1 {
            for token in tokens.reversed() {
                for candidate in singularCandidates(token) {
                    if let id = lookup[candidate] { return id }
                }
            }
        }

        // Tier 4: one-edit typos ("bannana" → banana). Only for words of 4+
        // characters — short words are one edit from too many neighbors.
        for token in ([normalized] + tokens.reversed()).filter({ $0.count >= 4 }) {
            if let id = typoMatch(token) { return id }
        }

        return .unknown
    }

    /// The token plus naive singular forms: "peppers" → "pepper",
    /// "tomatoes" → "tomato". Applied to lookups only, never to stored names.
    private static func singularCandidates(_ word: String) -> [String] {
        var candidates = [word]
        if word.hasSuffix("es"), word.count > 3 { candidates.append(String(word.dropLast(2))) }
        if word.hasSuffix("s"), word.count > 2 { candidates.append(String(word.dropLast(1))) }
        return candidates
    }

    /// Vocabulary display names ("ice_cream" → "ice cream") plus a small
    /// curated synonym table. Merged because both resolve the same way; the
    /// vocabulary is inserted last so it wins any accidental key overlap.
    private static let lookup: [String: ItemID] = {
        var table: [String: ItemID] = [
            "yoghurt": .yogurt,
            "capsicum": .pepper,
            "jalapeno": .pepper,
            "chili": .pepper,
            "chilli": .pepper,
            "aubergine": .eggplant,
            "scallion": .onion,
            "lime": .lemon,
            "clementine": .orange,
            "mandarin": .orange,
            "tangerine": .orange,
            "steak": .beef,
            "ham": .pork,
            "yam": .sweetPotato,
            "loaf": .bread,
            "baguette": .bread,
            "spaghetti": .pasta,
            "macaroni": .pasta,
            "ramen": .noodles,
            "oatmeal": .cereal,
            "oats": .cereal,
            "granola": .cereal,
            "ketchup": .sauce,
            "mustard": .sauce,
            "mayonnaise": .sauce,
            "mayo": .sauce,
            "salsa": .sauce,
            "cream": .dairy,
            "gelato": .iceCream,
        ]
        for id in ItemID.allCases where id != .unknown {
            table[id.rawValue.replacingOccurrences(of: "_", with: " ")] = id
        }
        return table
    }()

    /// Sorted for determinism: among equal-distance matches the
    /// lexicographically first key always wins.
    private static let typoKeys: [String] = lookup.keys.filter { $0.count >= 4 }.sorted()

    private static func typoMatch(_ word: String) -> ItemID? {
        for key in typoKeys where abs(key.count - word.count) <= 1 {
            if editDistanceIsAtMostOne(word, key) { return lookup[key] }
        }
        return nil
    }

    /// True iff the strings are within one insertion, deletion, or
    /// substitution of each other (a full Levenshtein matrix is overkill for
    /// a ≤1 threshold).
    private static func editDistanceIsAtMostOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 }        // substitution
            else if x.count > y.count { i += 1 }             // deletion from a
            else { j += 1 }                                  // insertion into a
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
