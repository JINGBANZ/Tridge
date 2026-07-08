import Foundation

/// Where the app finds the receipt-scan worker and the bearer token that proves
/// this build is Tridge. The URL is public; the token is a build secret written
/// into the bundled resource `ScanAPIToken.txt` at build time (by CI from the
/// `SCAN_API_TOKEN` secret, or locally) and never committed — see AGENTS.md and
/// wiki/decisions.md → 2026-07-07.
///
/// The token rides as a bundled resource rather than an Info.plist value because
/// Xcode's generated Info.plist silently drops custom `INFOPLIST_KEY_*` keys
/// (only Apple's own are honored); a bundled resource ships reliably and, when
/// absent, degrades to a clear "not set up" message instead of a crash.
enum ScanAPIConfig {
    /// Test-environment worker. Production will get a separate URL (and App
    /// Attest instead of the shared token) — see design/backend-design.html.
    static let baseURL = URL(string: "https://tridge-scan-api-test.forrestzjb.workers.dev")!

    /// The bearer token, or nil if this build wasn't configured with one
    /// (`ScanAPIToken.txt` absent or empty). Scanning then surfaces a clear
    /// failure rather than a silent 401 from the worker.
    static var token: String? {
        guard let url = Bundle.main.url(forResource: "ScanAPIToken", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// A ready-to-use scan client, or nil if the build carries no token.
    static var service: ProxyLLMService? {
        guard let token else { return nil }
        return ProxyLLMService(baseURL: baseURL, token: token)
    }
}
