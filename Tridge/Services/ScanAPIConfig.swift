import Foundation

/// Where the app finds the receipt-scan worker. One worker serves every build
/// today (Xcode-dev and TestFlight alike), authenticated with Apple App Attest
/// (`AppAttestAuthorizer`); the app carries no static token. See
/// wiki/decisions.md → 2026-07-10. When a dedicated production worker is added,
/// make this build-config-driven — `#if DEBUG` test URL, `#else` prod URL.
enum ScanAPIConfig {
    static let baseURL = URL(string: "https://tridge-scan-api-test.forrestzjb.workers.dev")!

    /// A scan client that authenticates with App Attest. Attestation is lazy, so
    /// this is cheap to build per scan; on unsupported hardware (the Simulator)
    /// the first request throws `LLMError.attestationUnavailable`.
    static var service: ProxyLLMService {
        ProxyLLMService(baseURL: baseURL, authorizer: AppAttestAuthorizer(baseURL: baseURL))
    }
}
