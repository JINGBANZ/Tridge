import Foundation
@testable import FridgeCore

/// What a fixture receipt is expected to parse into. Deliberately fuzzy: LLM
/// wording varies run to run, so items match on name keywords and ranges, not
/// verbatim output. See Fixtures/README.md for the JSON format.
struct ReceiptExpectation: Decodable {
    struct ExpectedItem: Decodable {
        /// Any of these (case-insensitive substrings) identifies the item.
        var name: [String]
        /// Acceptable ItemID rawValues, e.g. ["salmon", "fish"] — the LLM may
        /// reasonably land on either for a degraded receipt line.
        var id: [String]?
        var quantity: Int?
        var shelfLifeDays: DayRange?

        struct DayRange: Decodable {
            var min: Int?
            var max: Int?
        }

        private enum CodingKeys: String, CodingKey {
            case name, id, quantity
            case shelfLifeDays = "shelf_life_days"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // "name" and "id" may be a single string or a list of alternatives.
            if let single = try? c.decode(String.self, forKey: .name) {
                name = [single]
            } else {
                name = try c.decode([String].self, forKey: .name)
            }
            if let single = try? c.decode(String.self, forKey: .id) {
                id = [single]
            } else {
                id = try c.decodeIfPresent([String].self, forKey: .id)
            }
            quantity = try c.decodeIfPresent(Int.self, forKey: .quantity)
            shelfLifeDays = try c.decodeIfPresent(DayRange.self, forKey: .shelfLifeDays)
        }

        func matchesName(_ item: ParsedItem) -> Bool {
            let haystack = item.name.lowercased()
            return name.contains { haystack.contains($0.lowercased()) }
        }

        func fieldMismatches(in item: ParsedItem) -> [String] {
            var problems: [String] = []
            let label = "\"\(item.name)\""
            if let id, !id.contains(item.id.rawValue) {
                problems.append("\(label): id \(item.id.rawValue), expected one of \(id)")
            }
            if let quantity, item.quantity != quantity {
                problems.append("\(label): quantity \(item.quantity), expected \(quantity)")
            }
            if let range = shelfLifeDays {
                if let min = range.min, item.shelfLifeDays < min {
                    problems.append("\(label): shelf life \(item.shelfLifeDays)d, expected ≥ \(min)d")
                }
                if let max = range.max, item.shelfLifeDays > max {
                    problems.append("\(label): shelf life \(item.shelfLifeDays)d, expected ≤ \(max)d")
                }
            }
            return problems
        }
    }

    /// Optional path to the receipt image, relative to the fixture directory —
    /// used when the image lives elsewhere in the repo (e.g. shared with the
    /// app bundle) instead of inside the fixture folder.
    var image: String?
    var minItems: Int?
    var maxItems: Int?
    var items: [ExpectedItem]
    /// No parsed item name may contain these (catches non-food leakage).
    var absent: [String]?

    private enum CodingKeys: String, CodingKey {
        case image, items, absent
        case minItems = "min_items"
        case maxItems = "max_items"
    }

    /// Empty result = the parse meets every expectation.
    func mismatches(in receipt: ParsedReceipt) -> [String] {
        var problems: [String] = []

        if let minItems, receipt.items.count < minItems {
            problems.append("only \(receipt.items.count) items parsed, expected ≥ \(minItems)")
        }
        if let maxItems, receipt.items.count > maxItems {
            problems.append("\(receipt.items.count) items parsed, expected ≤ \(maxItems)")
        }

        // Each expected item must claim a distinct parsed item. Assignment is
        // a maximum bipartite matching (not a greedy scan): with overlapping
        // keywords like ["milk"] and ["whole"] against ["Whole Milk",
        // "Almond Milk"], greedy first-match could report a spurious miss
        // depending on listing order.
        let assignment = maximumMatching(candidatesPerExpected: items.map { expected in
            receipt.items.indices.filter { expected.matchesName(receipt.items[$0]) }
        })
        for (index, expected) in items.enumerated() {
            guard let parsedIndex = assignment[index] else {
                problems.append("missing item matching \(expected.name)")
                continue
            }
            problems += expected.fieldMismatches(in: receipt.items[parsedIndex])
        }

        for keyword in absent ?? [] {
            for item in receipt.items where item.name.lowercased().contains(keyword.lowercased()) {
                problems.append("forbidden keyword \"\(keyword)\" in parsed item \"\(item.name)\"")
            }
        }
        return problems
    }
}

/// Maximum bipartite matching via DFS augmenting paths (Kuhn's algorithm).
/// Returns, per expected-item index, the parsed-item index it claimed (nil if
/// no assignment exists). Fixture sizes are tiny, so O(V·E) is plenty.
func maximumMatching(candidatesPerExpected: [[Int]]) -> [Int?] {
    var parsedOwner: [Int: Int] = [:] // parsed index → expected index

    func assign(_ expected: Int, _ visited: inout Set<Int>) -> Bool {
        for parsed in candidatesPerExpected[expected] where !visited.contains(parsed) {
            visited.insert(parsed)
            if parsedOwner[parsed] == nil || assign(parsedOwner[parsed]!, &visited) {
                parsedOwner[parsed] = expected
                return true
            }
        }
        return false
    }

    for expected in candidatesPerExpected.indices {
        var visited = Set<Int>()
        _ = assign(expected, &visited)
    }

    var result = [Int?](repeating: nil, count: candidatesPerExpected.count)
    for (parsed, expected) in parsedOwner {
        result[expected] = parsed
    }
    return result
}
