import Foundation

/// The strict JSON Schema the LLM's reply is constrained to, server-side, via
/// OpenAI structured outputs. Single source of truth for the wire contract —
/// it must mirror ParsedReceipt/ParsedItem, which the tests cross-check.
///
/// Strict-mode rules: every object sets `additionalProperties: false` and
/// lists all keys in `required`; optionality is expressed as `["…","null"]`.
public enum ReceiptSchema {
    public static let name = "parsed_receipt"

    public static let json = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["store", "purchase_date", "items"],
      "properties": {
        "store": { "type": ["string", "null"] },
        "purchase_date": {
          "type": ["string", "null"],
          "description": "Purchase date printed on the receipt, formatted YYYY-MM-DD"
        },
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "receipt_text", "emoji", "category", "quantity",
                         "storage", "shelf_life_days", "confidence"],
            "properties": {
              "name": { "type": "string" },
              "receipt_text": { "type": ["string", "null"] },
              "emoji": { "type": "string" },
              "category": {
                "type": "string",
                "enum": ["produce", "dairy", "meat", "seafood", "frozen", "pantry",
                         "beverage", "bakery", "deli", "leftovers", "condiment", "other"]
              },
              "quantity": { "type": "integer" },
              "storage": { "type": "string", "enum": ["fridge", "freezer", "pantry"] },
              "shelf_life_days": { "type": "integer" },
              "confidence": { "type": "string", "enum": ["high", "low"] }
            }
          }
        }
      }
    }
    """

    /// The schema as a JSON object graph, ready to embed in a request body.
    public static func object() throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dictionary = parsed as? [String: Any] else {
            throw ReceiptParsingError.notJSON
        }
        return dictionary
    }
}
