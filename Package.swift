// swift-tools-version:5.10
// FridgeCore holds the pure logic (LLM response parsing + schema, the scan-API
// client, urgency rules) so it builds and tests on Linux via
// `swift test`; the iOS app target compiles the same sources directly (see
// Tridge.xcodeproj).
import PackageDescription

let package = Package(
    name: "FridgeCore",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    targets: [
        .target(
            name: "FridgeCore",
            path: "Tridge",
            // App/AccountTaskRegistry.swift is Foundation-only and holds the
            // account-transition drain, so it is tested on Linux too.
            sources: [
                "Core",
                "Services/LLMService.swift",
                "Services/ProxyLLMService.swift",
                "App/AccountTaskRegistry.swift",
            ]
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
