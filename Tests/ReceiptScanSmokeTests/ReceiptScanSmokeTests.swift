import XCTest
@testable import FridgeCore

/// Live end-to-end check of the receipt-scanning contract: every fixture image
/// goes through the real OpenAI structured-outputs call and the parsed
/// inventory must satisfy its expected.json. Guards against model/prompt/schema
/// regressions without deploying the app.
///
/// Needs an OpenAI key — from the OPENAI_API_KEY environment variable or the
/// gitignored `.env` at the repo root (each fixture costs a fraction of a
/// cent); skips cleanly otherwise, so plain `swift test` stays green.
final class ReceiptScanSmokeTests: XCTestCase {
    func testFixtureReceiptsParseToExpectedInventory() async throws {
        guard let apiKey = EnvFile.openAIKey() else {
            throw XCTSkip("No OPENAI_API_KEY (env or .env) — skipping live receipt smoke test. Copy env.sample → .env to set one up.")
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
