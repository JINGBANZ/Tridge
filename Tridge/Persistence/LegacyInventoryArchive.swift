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
/// Because it opens read-only it cannot lightweight-migrate an older archive.
/// It does not have to: the app's own SwiftData container still opens this store
/// read-write at launch and brings it to the current `FridgeItem` schema first.
/// Whichever step retires that container has to keep this reader running after a
/// launch that has already opened it, or migrate the schema itself.
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

        let container: ModelContainer
        do {
            // `allowsSave: false` is the enforcement, not a convention — the
            // archive must survive the migration byte-for-byte so the user can
            // still erase it deliberately. `.none` keeps a store that predates
            // the iCloud entitlement from mirroring itself into the container
            // the sharing stack owns.
            let configuration = ModelConfiguration(schema: Schema([FridgeItem.self]),
                                                   url: storeURL, allowsSave: false,
                                                   cloudKitDatabase: .none)
            container = try ModelContainer(for: FridgeItem.self, configurations: configuration)
        } catch {
            throw ReadError(diagnosticID: "legacy.open.\(Self.diagnosticID(for: error))")
        }

        let context = ModelContext(container)
        let items: [FridgeItem]
        do {
            // Unfiltered: the inventories involved are small, and reading the
            // status in Swift avoids depending on how a predicate compiles
            // against the archived schema.
            items = try context.fetch(FetchDescriptor<FridgeItem>())
        } catch {
            throw ReadError(diagnosticID: "legacy.read.\(Self.diagnosticID(for: error))")
        }

        return items.filter { $0.status == .active }.map(Self.row)
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
