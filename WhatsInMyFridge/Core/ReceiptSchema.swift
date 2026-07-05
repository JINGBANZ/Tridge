import Foundation

/// The strict JSON Schema the LLM's reply is constrained to, server-side, via
/// OpenAI structured outputs. Built programmatically so the `id` enum is
/// always exactly `ItemID.allCases` — the vocabulary can't drift from the code.
///
/// Strict-mode rules: every object sets `additionalProperties: false` and
/// lists all keys in `required`; optionality is expressed as `["…","null"]`.
public enum ReceiptSchema {
    public static let name = "parsed_receipt"

    public static func object() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["items"],
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "name", "receipt_text", "quantity",
                                     "shelf_life_days"],
                        "properties": [
                            "id": [
                                "type": "string",
                                "description": "Closest matching item id. Prefer a specific id; fall back to a generic bucket (fruit, vegetable, dairy, meat, seafood, bakery, beverage, grain, snack, condiment, frozen); use \"unknown\" only when the item cannot be identified.",
                                "enum": ItemID.allCases.map(\.rawValue),
                            ],
                            "name": ["type": "string"],
                            "receipt_text": ["type": ["string", "null"]],
                            "quantity": ["type": "integer"],
                            "shelf_life_days": ["type": "integer"],
                        ],
                    ],
                ],
            ],
        ]
    }
}
