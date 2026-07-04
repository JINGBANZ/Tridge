import Foundation

/// One food line as returned by the LLM (see the API contract in
/// design/fridge-design.html → "LLM integration").
public struct ParsedItem: Equatable, Sendable {
    public var name: String
    public var receiptText: String?
    public var emoji: String
    public var category: FoodCategory
    public var quantity: Int
    /// nil when the LLM omitted or garbled it; the app substitutes the user's
    /// default storage location from Settings.
    public var storage: StorageLocation?
    public var shelfLifeDays: Int
    public var confidence: Confidence

    public init(name: String, receiptText: String?, emoji: String, category: FoodCategory,
                quantity: Int, storage: StorageLocation?, shelfLifeDays: Int, confidence: Confidence) {
        self.name = name
        self.receiptText = receiptText
        self.emoji = emoji
        self.category = category
        self.quantity = quantity
        self.storage = storage
        self.shelfLifeDays = shelfLifeDays
        self.confidence = confidence
    }
}

extension ParsedItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, emoji, category, quantity, storage, confidence
        case receiptText = "receipt_text"
        case shelfLifeDays = "shelf_life_days"
    }

    // LLM output is untrusted: unknown enum strings, missing quantities, or a
    // stray non-integer must degrade the single item, never the whole parse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown item"
        receiptText = try c.decodeIfPresent(String.self, forKey: .receiptText)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        let categoryRaw = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        category = FoodCategory(rawValue: categoryRaw) ?? .other
        quantity = max(1, (try? c.decode(Int.self, forKey: .quantity)) ?? 1)
        let storageRaw = try c.decodeIfPresent(String.self, forKey: .storage) ?? ""
        storage = StorageLocation(rawValue: storageRaw)
        shelfLifeDays = max(0, (try? c.decode(Int.self, forKey: .shelfLifeDays)) ?? 7)
        let confidenceRaw = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        confidence = Confidence(rawValue: confidenceRaw) ?? .low
    }
}

/// The full LLM response for one receipt.
public struct ParsedReceipt: Decodable, Equatable, Sendable {
    public var store: String?
    public var purchaseDate: String?
    public var items: [ParsedItem]

    private enum CodingKeys: String, CodingKey {
        case store, items
        case purchaseDate = "purchase_date"
    }

    public init(store: String?, purchaseDate: String?, items: [ParsedItem]) {
        self.store = store
        self.purchaseDate = purchaseDate
        self.items = items
    }

    /// `purchase_date` ("YYYY-MM-DD") as a Date in `calendar`'s time zone.
    public func purchaseDateValue(calendar: Calendar = .current) -> Date? {
        guard let purchaseDate else { return nil }
        let parts = purchaseDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }
}

public enum ReceiptParsingError: Error, Equatable {
    case notJSON
}

/// Turns the raw LLM text reply into a ParsedReceipt.
public enum ReceiptResponseParser {
    public static func parse(_ raw: String) throws -> ParsedReceipt {
        let jsonText = extractJSON(from: raw)
        guard let data = jsonText.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(ParsedReceipt.self, from: data) else {
            throw ReceiptParsingError.notJSON
        }
        return receipt
    }

    /// Strips Markdown code fences and any prose around the JSON object.
    static func extractJSON(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"),
              first < last else { return text }
        return String(text[first...last])
    }
}
