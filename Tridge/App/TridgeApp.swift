import SwiftUI
import SwiftData

@main
struct TridgeApp: App {
    private let container: ModelContainer

    init() {
        do {
            // The sharing build added the iCloud entitlement, and SwiftData's
            // default `.automatic` would take that as permission to mirror this
            // store — receipt text included — into the container the Core Data
            // sharing stack owns. It stays local: the archive is only ever read
            // by the one-time upgrade (wiki/household-sharing.md → "Upgrade from
            // the shipping build"). Everything else about the configuration is
            // the default, so the store URL is unchanged.
            let configuration = ModelConfiguration(schema: Schema([FridgeItem.self]),
                                                   cloudKitDatabase: .none)
            container = try ModelContainer(for: FridgeItem.self, configurations: configuration)
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
        Self.backfillNormalizedNames(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
    }

    /// Rows created before `normalizedName` existed carry the schema default
    /// "" — recompute from `name` once. Idempotent, becomes a no-op.
    private static func backfillNormalizedNames(in context: ModelContext) {
        let stale = FetchDescriptor<FridgeItem>(
            predicate: #Predicate { $0.normalizedName == "" && $0.name != "" })
        guard let items = try? context.fetch(stale), !items.isEmpty else { return }
        for item in items {
            item.setName(item.name)
        }
        AppLog.scan.info("Backfilled normalizedName on \(items.count) items")
    }
}
