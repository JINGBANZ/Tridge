import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession on Linux, for the smoke-test target
#endif

/// Receipt photo → structured inventory via the Tridge scan API — a Cloudflare
/// Worker that holds the OpenAI key so the app never has to. The app POSTs the
/// raw JPEG with a bearer token; the worker runs the same schema-constrained
/// model call and returns the `ParsedReceipt` JSON this client hands straight to
/// `ReceiptResponseParser`. The worker already retries an unparseable model
/// reply once (see `server/src/index.ts`), so this client does not retry.
struct ProxyLLMService: LLMService {
    var baseURL: URL
    /// Bearer token proving the caller is Tridge; injected at build time, never
    /// user-supplied. See `ScanAPIConfig`.
    var token: String
    var session: URLSession = .shared

    private var endpoint: URL { baseURL.appendingPathComponent("v1/receipt-scan") }

    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await perform(request)
        } catch {
            AppLog.llm.error("Scan API network error: \(error.localizedDescription)")
            throw LLMError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            AppLog.llm.error("Non-HTTP response from scan API")
            throw LLMError.network(underlying: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The worker's error body is a safe `{"error":"…"}` message (never
            // keys or images), so it's fine to log for diagnostics.
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            AppLog.llm.error("Scan API HTTP \(http.statusCode): \(body)")
            switch http.statusCode {
            case 429: throw LLMError.rateLimited
            case 422: throw LLMError.unparseable // worker already retried once
            default: throw LLMError.apiFailure(status: http.statusCode)
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let receipt = try? ReceiptResponseParser.parse(text) else {
            AppLog.llm.error("Scan API reply didn't parse (\(data.count) bytes: \"\(text.prefix(200))\")")
            throw LLMError.unparseable
        }
        AppLog.llm.info("Parsed \(receipt.items.count) items")
        return receipt
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
