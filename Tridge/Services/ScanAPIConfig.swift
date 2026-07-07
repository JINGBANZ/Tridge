import Foundation

/// Where the app finds the receipt-scan worker and the bearer token that proves
/// this build is Tridge. The URL is public; the token is a build secret injected
/// via `Secrets.xcconfig` → `Info.plist` (`ScanAPIToken`) and never committed —
/// see `Secrets.sample.xcconfig` and wiki/decisions.md → 2026-07-07.
enum ScanAPIConfig {
    /// Test-environment worker. Production will get a separate URL (and App
    /// Attest instead of the shared token) — see design/backend-design.html.
    static let baseURL = URL(string: "https://tridge-scan-api-test.forrestzjb.workers.dev")!

    /// The bearer token, or nil if this build wasn't configured with one
    /// (`Secrets.xcconfig` missing). Scanning then surfaces a clear failure
    /// rather than a silent 401 from the worker.
    static var token: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ScanAPIToken") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// A ready-to-use scan client, or nil if the build carries no token.
    static var service: ProxyLLMService? {
        guard let token else { return nil }
        return ProxyLLMService(baseURL: baseURL, token: token)
    }
}
