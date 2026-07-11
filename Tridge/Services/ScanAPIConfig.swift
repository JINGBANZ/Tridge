import Foundation

/// Where the app finds the receipt-scan worker. One worker serves every build
/// today (Xcode-dev and TestFlight alike), authenticated with Apple App Attest
/// (`AppAttestAuthorizer`); the app carries no static token. See
/// wiki/decisions.md → 2026-07-10. When a dedicated production worker is added,
/// make this build-config-driven — `#if DEBUG` test URL, `#else` prod URL.
enum ScanAPIConfig {
    static let baseURL = URL(string: "https://tridge-scan-api-test.forrestzjb.workers.dev")!

    /// A scan client that authenticates with App Attest. One shared instance, so
    /// the authorizer's actor serializes registration across concurrent scans;
    /// attestation is lazy, and on unsupported hardware (the Simulator) the first
    /// request throws `LLMError.attestationUnavailable`.
    static let service = ProxyLLMService(baseURL: baseURL, authorizer: AppAttestAuthorizer(baseURL: baseURL))
}
