import Foundation
import SwiftData

/// The archived pre-sharing inventory, read exactly once during the upgrade.
///
/// Injected so the upgrade can be driven without a SwiftData store on disk.
protocol LegacyInventoryArchiveReading: Sendable {
    /// Whether the exact archive is still on this device. It is never moved,
    /// mutated, or automatically deleted — only the user's explicit Erase Old
    /// Local Inventory removes it.
    var exists: Bool { get }

    /// Every `active` row. Eaten and tossed rows stay behind in the archive.
    func readActiveRows() throws -> [LegacyInventoryRow]
}

/// Opens the shipping build's SwiftData store read-only, long enough to read its
/// active rows.
///
/// This reader is the only place the legacy schema is used after the upgrade: it
/// is never attached to the sharing stack, never saves, and never mirrors to
/// CloudKit (wiki/household-sharing.md → "Upgrade from the shipping build").
///
/// The sharing build no longer opens a SwiftData container of its own, so
/// nothing brings an older archive up to the shipping `FridgeItem` schema first
/// — and a read-only store cannot lightweight-migrate itself. An installation
/// updating from a build older than that schema therefore reads through a
/// throwaway copy: the migration runs on the copy, and the archive the user can
/// still choose to erase survives byte for byte.
struct LegacyInventoryArchive: LegacyInventoryArchiveReading {
    struct ReadError: Error, Equatable {
        let diagnosticID: String
    }

    /// The exact default SwiftData store, `Application Support/default.store`.
    /// Its `-wal`/`-shm` sidecars sit beside it under the same base name.
    static var defaultStoreURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
            .appendingPathComponent("default.store", isDirectory: false)
    }

    /// The sidecar suffixes SQLite writes beside the base file.
    static let sidecarSuffixes = ["-wal", "-shm"]

    /// Nil when Application Support cannot be resolved, which is the same
    /// answer as "there is no archive to migrate".
    let storeURL: URL?

    init(storeURL: URL? = LegacyInventoryArchive.defaultStoreURL) {
        self.storeURL = storeURL
    }

    var exists: Bool {
        guard let storeURL else { return false }
        return FileManager.default.fileExists(atPath: storeURL.path)
    }

    func readActiveRows() throws -> [LegacyInventoryRow] {
        guard let storeURL, exists else { return [] }
        do {
            return try Self.readRows(at: storeURL, allowsSave: false)
        } catch {
            // The likely cause is a schema older than the shipping one, which a
            // read-only store cannot migrate. Anything else fails again on the
            // copy and surfaces from there.
            return try Self.readRowsFromDisposableCopy(of: storeURL)
        }
    }

    /// Opens one store and returns its active rows.
    private static func readRows(at url: URL, allowsSave: Bool) throws -> [LegacyInventoryRow] {
        let container: ModelContainer
        do {
            // `.none` keeps a store that predates the iCloud entitlement from
            // mirroring itself into the container the sharing stack owns.
            let configuration = ModelConfiguration(schema: Schema([FridgeItem.self]),
                                                   url: url, allowsSave: allowsSave,
                                                   cloudKitDatabase: .none)
            container = try ModelContainer(for: FridgeItem.self, configurations: configuration)
        } catch {
            throw ReadError(diagnosticID: "legacy.open.\(diagnosticID(for: error))")
        }

        let context = ModelContext(container)
        let items: [FridgeItem]
        do {
            // Unfiltered: the inventories involved are small, and reading the
            // status in Swift avoids depending on how a predicate compiles
            // against the archived schema.
            items = try context.fetch(FetchDescriptor<FridgeItem>())
        } catch {
            throw ReadError(diagnosticID: "legacy.read.\(diagnosticID(for: error))")
        }

        return items.filter { $0.status == .active }.map(row)
    }

    /// Migrates and reads a copy, then deletes it.
    ///
    /// The copy is what makes `allowsSave: false` a real guarantee rather than
    /// a convention: the archive must survive the migration untouched so the
    /// user can still erase it deliberately, and a lightweight migration would
    /// otherwise rewrite it in place.
    private static func readRowsFromDisposableCopy(of url: URL) throws -> [LegacyInventoryRow] {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("LegacyArchiveRead-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: directory) }

        let copy = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: copy)
            for suffix in sidecarSuffixes {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                guard manager.fileExists(atPath: sidecar.path) else { continue }
                try manager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        } catch {
            throw ReadError(diagnosticID: "legacy.copy.\(diagnosticID(for: error))")
        }
        return try readRows(at: copy, allowsSave: true)
    }

    /// Receipt text is not read at all, so it cannot reach a Household store.
    private static func row(_ item: FridgeItem) -> LegacyInventoryRow {
        LegacyInventoryRow(id: item.id, name: item.name, artKey: item.artKey,
                           quantity: item.quantity, storageRaw: item.storageRaw,
                           purchaseDate: item.purchaseDate, expiryDate: item.expiryDate,
                           expirySourceRaw: item.expirySourceRaw)
    }

    /// An error domain and code — never a path, which would carry the account
    /// directory into a log.
    private static func diagnosticID(for error: Error) -> String {
        let details = error as NSError
        return "\(details.domain).\(details.code)"
    }
}
