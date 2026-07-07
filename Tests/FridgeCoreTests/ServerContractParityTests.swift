import XCTest
@testable import FridgeCore

/// During the BYOK→proxy migration the LLM contract (prompt + response
/// schema) exists twice: in the app (`OpenAIService` / `ReceiptSchema`) and in
/// the worker (`server/src/contract.ts` / `receipt-schema.json`). These tests
/// pin the copies together — edit one side and `swift test` fails until the
/// other side matches.
final class ServerContractParityTests: XCTestCase {
    /// Repo-root-relative access; works on Linux and macOS CI because tests
    /// always run from a full checkout.
    private var serverSrc: URL {
        URL(fileURLWithPath: #filePath)         // Tests/FridgeCoreTests/ServerContractParityTests.swift
            .deletingLastPathComponent()        // Tests/FridgeCoreTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("server/src")
    }

    func testServerSchemaMatchesReceiptSchema() throws {
        let data = try Data(contentsOf: serverSrc.appendingPathComponent("receipt-schema.json"))
        let server = try JSONSerialization.jsonObject(with: data)
        XCTAssertEqual(
            server as? NSDictionary, ReceiptSchema.object() as NSDictionary,
            "server/src/receipt-schema.json must equal ReceiptSchema.object() — including id enum order"
        )
    }

    func testServerPromptMatchesOpenAIServicePrompt() throws {
        let contract = try String(
            contentsOf: serverSrc.appendingPathComponent("contract.ts"), encoding: .utf8)
        XCTAssertTrue(
            contract.contains(OpenAIService.prompt),
            "server/src/contract.ts PROMPT must contain OpenAIService.prompt verbatim"
        )
    }
}
