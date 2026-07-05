import Foundation
@testable import FridgeCore

/// What a fixture receipt is expected to parse into. Deliberately fuzzy: LLM
/// wording varies run to run, so items match on name keywords and ranges, not
/// verbatim output. See Fixtures/README.md for the JSON format.
struct ReceiptExpectation: Decodable {
    struct ExpectedItem: Decodable {
        /// Any of these (case-insensitive substrings) identifies the item.
        var name: [String]
        /// Exact ItemID rawValue, e.g. "milk".
        var id: String?
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
            // "name" may be a single string or a list of alternatives.
            if let single = try? c.decode(String.self, forKey: .name) {
                name = [single]
            } else {
                name = try c.decode([String].self, forKey: .name)
            }
            id = try c.decodeIfPresent(String.self, forKey: .id)
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
            if let id, item.id.rawValue != id {
                problems.append("\(label): id \(item.id.rawValue), expected \(id)")
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

    var minItems: Int?
    var maxItems: Int?
    var items: [ExpectedItem]
    /// No parsed item name may contain these (catches non-food leakage).
    var absent: [String]?

    private enum CodingKeys: String, CodingKey {
        case items, absent
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

        // Each expected item must claim a distinct parsed item.
        var unclaimed = receipt.items
        for expected in items {
            guard let index = unclaimed.firstIndex(where: expected.matchesName) else {
                problems.append("missing item matching \(expected.name)")
                continue
            }
            problems += expected.fieldMismatches(in: unclaimed.remove(at: index))
        }

        for keyword in absent ?? [] {
            for item in receipt.items where item.name.lowercased().contains(keyword.lowercased()) {
                problems.append("forbidden keyword \"\(keyword)\" in parsed item \"\(item.name)\"")
            }
        }
        return problems
    }
}
