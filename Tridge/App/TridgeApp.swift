import SwiftUI
import SwiftData

@main
struct TridgeApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: FridgeItem.self)
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
