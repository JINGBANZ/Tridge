import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession on Linux, for the smoke-test target
#endif

/// Supplies the auth headers that prove a scan request comes from Tridge. The
/// production app signs each request with Apple App Attest (`AppAttestAuthorizer`,
/// iOS-only); the Linux smoke test uses a static bearer token
/// (`BearerTokenAuthorizer`). Kept a protocol so `ProxyLLMService` — which is
/// shared between the app and the Linux test target — carries no App Attest code.
protocol ScanRequestAuthorizer: Sendable {
    /// Headers to attach to a scan POST for this exact image. May perform I/O
    /// (App Attest registers the device and signs the image on first use).
    func authorizationHeaders(forImage imageData: Data) async throws -> [String: String]
}

/// Static bearer-token auth. The token never ships in the app; it authenticates
/// only the local receipt smoke-test harness against the test worker.
struct BearerTokenAuthorizer: ScanRequestAuthorizer {
    let token: String
    func authorizationHeaders(forImage imageData: Data) async throws -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }
}

/// Receipt photo → structured inventory via the Tridge scan API — a Cloudflare
/// Worker that holds the OpenAI key so the app never has to. The app POSTs the
/// raw JPEG with an authorizer's headers; the worker runs the same
/// schema-constrained model call and returns the `ParsedReceipt` JSON this
/// client hands straight to `ReceiptResponseParser`. The worker already retries
/// an unparseable model reply once (see `server/src/index.ts`), so this client
/// does not retry.
struct ProxyLLMService: LLMService {
    var baseURL: URL
    /// Proves the caller is Tridge — App Attest in the app, bearer token in the
    /// smoke test. See `ScanRequestAuthorizer`.
    var authorizer: any ScanRequestAuthorizer
    var session: URLSession = .shared

    /// Convenience for the smoke-test harness: authenticate with a bearer token.
    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.init(baseURL: baseURL, authorizer: BearerTokenAuthorizer(token: token), session: session)
    }

    init(baseURL: URL, authorizer: any ScanRequestAuthorizer, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authorizer = authorizer
        self.session = session
    }

    private var endpoint: URL { baseURL.appendingPathComponent("v1/receipt-scan") }

    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData

        // Attach auth last: App Attest signs over the exact image bytes.
        for (field, value) in try await authorizer.authorizationHeaders(forImage: jpegData) {
            request.setValue(value, forHTTPHeaderField: field)
        }

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
