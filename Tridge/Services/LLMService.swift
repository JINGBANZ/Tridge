import Foundation

enum LLMError: LocalizedError {
    case network(underlying: Error?)
    case rateLimited
    case apiFailure(status: Int)
    case unparseable
    /// The device can't produce an Apple App Attest assertion (unsupported
    /// hardware such as the Simulator, or attestation was refused).
    case attestationUnavailable

    var errorDescription: String? {
        switch self {
        case .network:
            "Couldn't reach the parsing service. Check your connection and try again."
        case .rateLimited:
            "You've scanned a lot in a short time. Wait a minute and try again."
        case .apiFailure(let status):
            "The parsing service returned an error (\(status)). Please try again."
        case .unparseable:
            "Couldn't make sense of that receipt. Try scanning it again."
        case .attestationUnavailable:
            "This device can't verify the app for scanning. Try on a real iPhone, or add items manually."
        }
    }
}

/// Receipt photo → structured inventory. A protocol so the scan flow doesn't
/// care whether the request goes to the backend proxy (`ProxyLLMService`) or,
/// in tests, straight at the same worker.
protocol LLMService {
    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt
}
