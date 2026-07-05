import XCTest
@testable import FridgeCore

/// Live end-to-end check of the receipt-scanning contract: every fixture image
/// goes through the real OpenAI structured-outputs call and the parsed
/// inventory must satisfy its expected.json. Guards against model/prompt/schema
/// regressions without deploying the app.
///
/// Needs OPENAI_API_KEY in the environment (each fixture costs a fraction of a
/// cent); skips cleanly otherwise, so plain `swift test` and CI stay green.
final class ReceiptScanSmokeTests: XCTestCase {
    func testFixtureReceiptsParseToExpectedInventory() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw XCTSkip("OPENAI_API_KEY not set — skipping live receipt smoke test.")
        }
        let fixtures = try ReceiptFixture.loadAll()
        try XCTSkipIf(fixtures.isEmpty,
                      "No fixtures found — add <name>/{receipt.jpg, expected.json} under Tests/ReceiptScanSmokeTests/Fixtures/.")

        let service = OpenAIService(apiKey: apiKey)
        for fixture in fixtures {
            let receipt = try await service.parseReceipt(jpegData: fixture.imageData)
            let problems = fixture.expectation.mismatches(in: receipt)
            XCTAssertTrue(problems.isEmpty, """
            Fixture "\(fixture.name)" failed \(problems.count) expectation(s):
            \(problems.map { "  • " + $0 }.joined(separator: "\n"))
            Parsed items: \(receipt.items.map { "\($0.name) ×\($0.quantity)" }.joined(separator: ", "))
            """)
        }
    }
}
