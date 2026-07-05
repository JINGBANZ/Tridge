import Foundation

/// Resolves the OpenAI key for the live smoke tests: the OPENAI_API_KEY
/// environment variable wins, else the gitignored `.env` at the repo root
/// (copy `env.sample` and fill it in).
enum EnvFile {
    static func openAIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        return value(of: "OPENAI_API_KEY", in: repoRoot().appendingPathComponent(".env"))
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
