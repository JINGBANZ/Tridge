import Foundation

enum LLMError: LocalizedError {
    case missingKey
    case network(underlying: Error?)
    case apiFailure(status: Int)
    case unparseable

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Add your Anthropic API key in Settings to scan receipts."
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

/// Direct Anthropic Messages API client (no backend in v1; the key comes from
/// Keychain via Settings).
struct AnthropicService: LLMService {
    var apiKey: String
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5"

    /// The receipt prompt, verbatim from the spec.
    static let prompt = """
    This is a grocery store receipt. Extract every FOOD and BEVERAGE item.
    Rules:
    - Expand abbreviations into clean, human-friendly names ("WHL MLK 1GAL" → "Whole Milk").
    - Skip non-food lines: tax, totals, coupons, bags, household goods, loyalty points.
    - If one line has a quantity multiplier, set quantity accordingly.
    - For each item, estimate typical shelf life in days for the storage you recommend,
      counted from the purchase date, assuming it was refrigerated promptly.
    - Pick exactly one emoji that best represents each item.
    - If a line is probably food but you cannot identify it, include it with
      name "Unknown item", confidence "low".
    Respond with ONLY this JSON, no prose:
    { "store": string|null, "purchase_date": "YYYY-MM-DD"|null,
      "items": [{ "name": string, "receipt_text": string, "emoji": string,
                  "category": "produce|dairy|meat|seafood|frozen|pantry|beverage|bakery|deli|leftovers|condiment|other",
                  "quantity": int, "storage": "fridge|freezer|pantry",
                  "shelf_life_days": int, "confidence": "high|low" }] }
    """

    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt {
        let text = try await requestText(prompt: Self.prompt, jpegData: jpegData)
        if let receipt = try? ReceiptResponseParser.parse(text) { return receipt }
        // One automatic retry with a stronger format reminder, per spec.
        let retryText = try await requestText(prompt: Self.prompt + "\nReturn valid JSON only.",
                                              jpegData: jpegData)
        guard let receipt = try? ReceiptResponseParser.parse(retryText) else {
            throw LLMError.unparseable
        }
        return receipt
    }

    // MARK: Request plumbing

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: [Content]
        }
        struct Content: Encodable {
            struct ImageSource: Encodable {
                var type = "base64"
                var mediaType = "image/jpeg"
                var data: String
                enum CodingKeys: String, CodingKey {
                    case type, data
                    case mediaType = "media_type"
                }
            }
            var type: String
            var source: ImageSource?
            var text: String?
        }
        var model: String
        var maxTokens: Int
        var messages: [Message]
        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Content: Decodable {
            var type: String
            var text: String?
        }
        var content: [Content]
    }

    private func requestText(prompt: String, jpegData: Data) async throws -> String {
        let body = RequestBody(
            model: Self.model,
            maxTokens: 2000,
            messages: [.init(role: "user", content: [
                .init(type: "image",
                      source: .init(data: jpegData.base64EncodedString()),
                      text: nil),
                .init(type: "text", source: nil, text: prompt),
            ])])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

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
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMError.unparseable
        }
        return decoded.content.compactMap(\.text).joined()
    }
}
