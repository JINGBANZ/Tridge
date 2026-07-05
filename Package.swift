// swift-tools-version:5.10
// FridgeCore holds the pure logic (LLM response parsing, urgency rules, date-label
// regex) so it builds and tests on Linux via `swift test`; the iOS app target
// compiles the same sources directly (see WhatsInMyFridge.xcodeproj).
import PackageDescription

let package = Package(
    name: "FridgeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(
            name: "FridgeCore",
            path: "WhatsInMyFridge/Core"
        ),
        .testTarget(
            name: "FridgeCoreTests",
            dependencies: ["FridgeCore"],
            path: "Tests/FridgeCoreTests"
        ),
    ]
)
