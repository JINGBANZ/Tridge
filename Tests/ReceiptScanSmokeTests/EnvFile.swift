import Foundation

/// Resolves the scan-API config for the live smoke tests from the environment,
/// falling back to the gitignored `.env` at the repo root (copy `env.sample`
/// and fill it in).
enum EnvFile {
    /// Bearer token for the scan-API worker (same value as its `SCAN_API_TOKEN`
    /// secret). No token → the smoke test skips.
    static func scanAPIToken() -> String? {
        envOrDotenv("SCAN_API_TOKEN")
    }

    /// Worker base URL — override with `BACKEND_URL`, else the test worker.
    static func scanAPIBaseURL() -> URL {
        let raw = envOrDotenv("BACKEND_URL") ?? "https://tridge-scan-api-test.forrestzjb.workers.dev"
        return URL(string: raw)!
    }

    private static func envOrDotenv(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }
        return value(of: name, in: repoRoot().appendingPathComponent(".env"))
    }

    /// Tests/ReceiptScanSmokeTests/EnvFile.swift → repo root.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func value(of name: String, in file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
