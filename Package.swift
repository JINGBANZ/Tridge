// swift-tools-version:5.10
// FridgeCore holds the pure logic (LLM response parsing + schema, the OpenAI
// client, urgency rules, date-label regex) so it builds and tests on Linux via
// `swift test`; the iOS app target compiles the same sources directly (see
// WhatsInMyFridge.xcodeproj).
import PackageDescription

let package = Package(
    name: "FridgeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(
            name: "FridgeCore",
            path: "WhatsInMyFridge",
            sources: ["Core", "Services/LLMService.swift"]
        ),
        .testTarget(
            name: "FridgeCoreTests",
            dependencies: ["FridgeCore"],
            path: "Tests/FridgeCoreTests"
        ),
        // Live integration tests: fixture receipt images → real OpenAI call →
        // fuzzy inventory expectations. Skipped unless OPENAI_API_KEY is set.
        .testTarget(
            name: "ReceiptScanSmokeTests",
            dependencies: ["FridgeCore"],
            path: "Tests/ReceiptScanSmokeTests",
            exclude: ["Fixtures"]
        ),
    ]
)
