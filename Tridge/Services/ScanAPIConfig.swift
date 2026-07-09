import Foundation

/// Where the app finds the receipt-scan worker. The URL is build-config-driven:
/// Debug builds (including on-device Xcode runs) hit the test worker; Release
/// builds — which is what TestFlight and the App Store ship — hit production.
/// Both are authenticated with Apple App Attest (`AppAttestAuthorizer`); the app
/// carries no static token. See wiki/decisions.md → 2026-07-09.
enum ScanAPIConfig {
    static let baseURL: URL = {
        #if DEBUG
        URL(string: "https://tridge-scan-api-test.forrestzjb.workers.dev")!
        #else
        URL(string: "https://tridge-scan-api.forrestzjb.workers.dev")!
        #endif
    }()

    /// A scan client that authenticates with App Attest. Attestation is lazy, so
    /// this is cheap to build per scan; on unsupported hardware (the Simulator)
    /// the first request throws `LLMError.attestationUnavailable`.
    static var service: ProxyLLMService {
        ProxyLLMService(baseURL: baseURL, authorizer: AppAttestAuthorizer(baseURL: baseURL))
    }
}
