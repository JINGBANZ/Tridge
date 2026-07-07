import Foundation

/// One food line as returned by the LLM (see the API contract in
/// design/fridge-design.html → "LLM integration").
public struct ParsedItem: Equatable, Sendable {
    /// Curated vocabulary id — drives the artwork. Never free-form.
    public var id: ItemID
    public var name: String
    public var receiptText: String?
    public var quantity: Int
    public var shelfLifeDays: Int

    public init(id: ItemID, name: String, receiptText: String?, quantity: Int,
                shelfLifeDays: Int) {
        self.id = id
        self.name = name
        self.receiptText = receiptText
        self.quantity = quantity
        self.shelfLifeDays = shelfLifeDays
    }
}

extension ParsedItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, quantity
        case receiptText = "receipt_text"
        case shelfLifeDays = "shelf_life_days"
    }

    // LLM output is untrusted: ids outside the shipped vocabulary (e.g. added
    // server-side later), missing quantities, or a stray non-integer must
    // degrade the single item, never the whole parse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let idRaw = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = ItemID(rawValue: idRaw) ?? .unknown
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown item"
        receiptText = try c.decodeIfPresent(String.self, forKey: .receiptText)
        quantity = max(1, (try? c.decode(Int.self, forKey: .quantity)) ?? 1)
        shelfLifeDays = max(0, (try? c.decode(Int.self, forKey: .shelfLifeDays)) ?? 7)
    }
}

/// The full LLM response for one receipt. Purchase metadata is deliberately
/// absent: the app stamps purchaseDate with the day the photo was taken.
public struct ParsedReceipt: Decodable, Equatable, Sendable {
    public var items: [ParsedItem]

    public init(items: [ParsedItem]) {
        self.items = items
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
