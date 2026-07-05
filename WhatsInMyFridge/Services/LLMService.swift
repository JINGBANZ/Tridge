import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession on Linux, for the smoke-test target
#endif

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

/// Direct OpenAI Responses API client (no backend in v1; the key comes from
/// Keychain via Settings). The reply is constrained server-side to
/// `ReceiptSchema` via strict structured outputs, so the shape is enforced —
/// not merely requested in the prompt.
struct OpenAIService: LLMService {
    var apiKey: String
    var session: URLSession = .shared
    var storeResponses = false

    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
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
        if let receipt = try? ReceiptResponseParser.parse(text) {
            AppLog.llm.info("Parsed \(receipt.items.count) items")
            return receipt
        }
        // Schema enforcement makes malformed JSON rare (truncation/refusal),
        // but the spec's one automatic retry still applies.
        AppLog.llm.error("Reply didn't parse (\(text.count) chars: \"\(text.prefix(200))\") — retrying once")
        let retryText = try await requestText(jpegData: jpegData)
        guard let receipt = try? ReceiptResponseParser.parse(retryText) else {
            AppLog.llm.error("Retry didn't parse either (\(retryText.count) chars) — giving up")
            throw LLMError.unparseable
        }
        AppLog.llm.info("Retry parsed \(receipt.items.count) items")
        return receipt
    }

    // MARK: Request plumbing

    private struct ResponseBody: Decodable {
        struct OutputItem: Decodable {
            struct Content: Decodable {
                var type: String
                var text: String?
                var refusal: String?
            }
            var type: String
            var content: [Content]?
        }
        var status: String?
        var output: [OutputItem]
    }

    private func requestText(jpegData: Data) async throws -> String {
        // Built with JSONSerialization because the schema is itself a JSON
        // object graph; Codable would need a wrapper type per nesting level.
        let body: [String: Any] = [
            "model": Self.model,
            // Generous cap: gpt-5 reasoning tokens count against it.
            "max_output_tokens": 4000,
            "reasoning": ["effort": "low"],
            // Production scans are personal data; smoke tests opt in so failed
            // fixture runs can be inspected in OpenAI's dashboard.
            "store": storeResponses,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_image",
                     "image_url": "data:image/jpeg;base64,\(jpegData.base64EncodedString())"],
                    ["type": "input_text", "text": Self.prompt],
                ],
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
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
            (data, response) = try await perform(request)
        } catch {
            AppLog.llm.error("Network error: \(error.localizedDescription)")
            throw LLMError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            AppLog.llm.error("Non-HTTP response from OpenAI")
            throw LLMError.network(underlying: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The error body names the exact cause (bad param, quota, model);
            // never log the request (it holds the key header + image).
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            AppLog.llm.error("OpenAI HTTP \(http.statusCode): \(body)")
            throw LLMError.apiFailure(status: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            AppLog.llm.error("Unrecognized response shape: \(String(decoding: data.prefix(400), as: UTF8.self))")
            throw LLMError.unparseable
        }
        // The output timeline interleaves reasoning and message items; the
        // reply text lives in message items' output_text content.
        let contents = decoded.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if let refusal = contents.first(where: { $0.type == "refusal" })?.refusal {
            AppLog.llm.error("Model refusal: \(refusal.prefix(200))")
            throw LLMError.unparseable
        }
        let text = contents.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        guard !text.isEmpty else {
            AppLog.llm.error("Empty output, status \(decoded.status ?? "unknown") (likely token-limit truncation)")
            throw LLMError.unparseable
        }
        return text
    }

    /// Completion-handler bridge: Linux's FoundationNetworking has no async
    /// `data(for:)`, and this file must run there for the smoke tests.
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                }
            }.resume()
        }
    }
}
