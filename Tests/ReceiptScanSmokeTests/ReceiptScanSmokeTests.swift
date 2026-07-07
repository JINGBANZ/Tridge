import XCTest
@testable import FridgeCore

/// Live end-to-end check of the receipt-scanning contract: every fixture image
/// goes through the deployed scan-API worker (real OpenAI structured-outputs
/// call, server-side) and the parsed inventory must satisfy its expected.json.
/// Guards against model/prompt/schema regressions without deploying the app.
///
/// Needs the worker bearer token — from the SCAN_API_TOKEN environment variable
/// or the gitignored `.env` at the repo root (each fixture costs a fraction of a
/// cent); skips cleanly otherwise, so plain `swift test` stays green. Override
/// the target with BACKEND_URL.
final class ReceiptScanSmokeTests: XCTestCase {
    func testFixtureReceiptsParseToExpectedInventory() async throws {
        guard let token = EnvFile.scanAPIToken() else {
            throw XCTSkip("No SCAN_API_TOKEN (env or .env) — skipping live receipt smoke test. Copy env.sample → .env to set one up.")
        }
        let fixtures = try ReceiptFixture.loadAll()
        try XCTSkipIf(fixtures.isEmpty,
                      "No fixtures found — add <name>/{receipt.jpg, expected.json} under Tests/ReceiptScanSmokeTests/Fixtures/.")

        let service = ProxyLLMService(baseURL: EnvFile.scanAPIBaseURL(), token: token)
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
