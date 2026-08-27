import SwiftUI

@main
struct TridgeApp: App {
    /// One coordinator for the process: it owns account validation, the two
    /// Core Data stores, and the Active Household's snapshots. Nothing in the
    /// app runtime opens a store or a model context of its own.
    @State private var coordinator: AccountSessionCoordinator

    init() {
        // The monitor is created first and handed over unstarted: the
        // coordinator installs its observation *before* the stores load, so a
        // setup or import that runs during the load is buffered rather than
        // lost (wiki/household-sharing.md → "Adopt, do not reinvent").
        let coordinator = AccountSessionCoordinator(syncMonitor: StoreScopedSyncMonitor())
        _coordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}
