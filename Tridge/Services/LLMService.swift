import Foundation

enum LLMError: LocalizedError {
    case network(underlying: Error?)
    case rateLimited
    case apiFailure(status: Int)
    case unparseable

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
        }
    }
}

/// Receipt photo → structured inventory. A protocol so the scan flow doesn't
/// care whether the request goes to the backend proxy (`ProxyLLMService`) or,
/// in tests, straight at the same worker.
protocol LLMService {
    func parseReceipt(jpegData: Data) async throws -> ParsedReceipt
}
