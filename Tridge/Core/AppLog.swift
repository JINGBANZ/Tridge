import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// One log category with a uniform API on Apple platforms (os.Logger) and
/// Linux (stdout) — this file also builds in the FridgeCore package so the
/// smoke tests get the same log lines the app produces.
///
/// Messages are logged `.public` by design: they are the payload of the
/// Settings → "Copy diagnostics" feedback loop, so never log secrets (API
/// keys) or bulky data (image bytes) through here.
public struct LogChannel: Sendable {
    public let category: String
    #if canImport(OSLog)
    private let logger: Logger
    #endif

    init(_ category: String) {
        self.category = category
        #if canImport(OSLog)
        logger = Logger(subsystem: AppLog.subsystem, category: category)
        #endif
    }

    public func info(_ message: String) {
        #if canImport(OSLog)
        logger.info("\(message, privacy: .public)")
        #else
        print("[\(category)] \(message)")
        #endif
    }

    public func error(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)")
        #else
        print("[\(category)] ERROR: \(message)")
        #endif
    }
}

public enum AppLog {
    public static let subsystem = "com.tridge"

    public static let scan = LogChannel("scan")
    public static let llm = LogChannel("llm")
    public static let ocr = LogChannel("ocr")
    /// Household sharing: store lifecycle, sync state, and content-free
    /// integrity findings. Never a household or item name.
    public static let household = LogChannel("household")
    /// Key-storage failures only — status codes, never key material.
    public static let keychain = LogChannel("keychain")

    #if canImport(OSLog)
    /// This session's app log entries plus an app/OS header — the payload
    /// behind Settings → "Copy diagnostics". Only entries from the current
    /// launch are available; reproduce the problem before copying.
    public static func recentDiagnostics(lastMinutes: Int = 60) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = [
            "Tridge diagnostics",
            "App \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Captured \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
        ]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-Double(lastMinutes) * 60))
            // Filter in the store, not in Swift: without a predicate getEntries
            // decodes every subsystem's entries for the process — the expensive
            // work behind the copy-diagnostics stall.
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let entries = try store.getEntries(at: position, matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
                .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
            lines += entries.isEmpty ? ["(no app log entries this session)"] : entries
        } catch {
            lines.append("Couldn't read the log store: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
