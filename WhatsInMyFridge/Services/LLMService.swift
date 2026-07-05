import Foundation

enum LLMError: LocalizedError {
    case missingKey
    case network(underlying: Error?)
    case apiFailure(status: Int)
    case unparseable

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Add your OpenAI API key in Settings to scan receipts."
        case .network:
            "Couldn't reach the parsing service. Check your connection and try again."
        case .apiFailure(let status):
            status == 401
                ? "Your API key was rejected. Double-check it in Settings."
                : "The parsing service returned an error (\(status)). Please try again."
        case .unparseable:
            "Couldn't make sense of that receipt. Try scanning it again."
        }
    }
}

/// Receipt photo → structured inventory. Protocol so the direct-API client can
/// be swapped for a proxy backend later without touching the scan flow.
protocol LLMService {
    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt
}

/// Direct OpenAI Chat Completions client (no backend in v1; the key comes from
/// Keychain via Settings). The reply is constrained server-side to
/// `ReceiptSchema` via strict structured outputs, so the shape is enforced —
/// not merely requested in the prompt.
struct OpenAIService: LLMService {
    var apiKey: String
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let model = "gpt-5-mini"

    /// Content rules only — the response shape and the allowed "id" values are
    /// enforced by ReceiptSchema.
    static let prompt = """
    This is a grocery store receipt. Extract every FOOD and BEVERAGE item.
    Rules:
    - Expand abbreviations into clean, human-friendly names ("WHL MLK 1GAL" → "Whole Milk").
    - Skip non-food lines: tax, totals, coupons, bags, household goods, loyalty points.
    - If one line has a quantity multiplier, set quantity accordingly.
    - Estimate each item's typical shelf life in days from purchase, assuming it
      is stored appropriately at home (refrigerated promptly where applicable).
    - For "id", pick the closest match from the allowed values. Prefer a specific
      id; if nothing specific fits, pick a generic one (fruit, vegetable, dairy,
      meat, seafood, bakery, beverage, grain, snack, condiment, frozen).
    - If a line is probably food but you cannot tell what it is, use id "unknown"
      and name "Unknown item".
    """

    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt {
        let text = try await requestText(jpegData: jpegData)
        if let receipt = try? ReceiptResponseParser.parse(text) { return receipt }
        // Schema enforcement makes malformed JSON rare (truncation/refusal),
        // but the spec's one automatic retry still applies.
        let retryText = try await requestText(jpegData: jpegData)
        guard let receipt = try? ReceiptResponseParser.parse(retryText) else {
            throw LLMError.unparseable
        }
        return receipt
    }

    // MARK: Request plumbing

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
                var refusal: String?
            }
            var message: Message
        }
        var choices: [Choice]
    }

    private func requestText(jpegData: Data) async throws -> String {
        // Built with JSONSerialization because the schema is itself a JSON
        // object graph; Codable would need a wrapper type per nesting level.
        let body: [String: Any] = [
            "model": Self.model,
            // Generous cap: gpt-5 reasoning tokens count against it.
            "max_completion_tokens": 4000,
            "reasoning_effort": "low",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64,\(jpegData.base64EncodedString())"]],
                    ["type": "text", "text": Self.prompt],
                ],
            ]],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": ReceiptSchema.name,
                    "strict": true,
                    "schema": ReceiptSchema.object(),
                ],
            ],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network(underlying: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.apiFailure(status: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let message = decoded.choices.first?.message,
              message.refusal == nil,
              let content = message.content else {
            throw LLMError.unparseable
        }
        return content
    }
}
