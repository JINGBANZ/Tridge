import SwiftUI

@main
struct TridgeApp: App {
    /// Present only to add CloudKit's invitation callbacks to SwiftUI's scene.
    /// It creates no window; SwiftUI still owns the interface.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One coordinator for the process: it owns account validation, the two
    /// Core Data stores, and the Active Household's snapshots. Nothing in the
    /// app runtime opens a store or a model context of its own.
    @State private var coordinator: AccountSessionCoordinator

    init() {
        // The monitor is created first and handed over unstarted: the
        // coordinator installs its observation *before* the stores load, so a
        // setup or import that runs during the load is buffered rather than
        // lost (wiki/household-sharing.md → "Adopt, do not reinvent").
        _coordinator = State(initialValue: Self.makeCoordinator(StoreScopedSyncMonitor()))
    }

    private static func makeCoordinator(
        _ syncMonitor: any SyncStatusProviding
    ) -> AccountSessionCoordinator {
#if DEBUG
        // A Simulator build with no iCloud entitlement cannot construct a
        // CloudKit container at all, so this is the only way to see the app
        // before `iCloud.com.tridge.app` exists.
        if LocalOnlyLaunch.isRequested {
            return LocalOnlyLaunch.coordinator()
        }
#endif
        return AccountSessionCoordinator(syncMonitor: syncMonitor)
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}

extension ProcessInfo {
    /// Whether this process was launched to host an XCTest bundle.
    ///
    /// `TridgeTests` is hosted by this app, so running it launches `TridgeApp`.
    /// The suites build their own account sessions against local-only stacks,
    /// and the host must not open one of its own: an unsigned simulator build
    /// carries no iCloud entitlement, and `CKContainer` will not be constructed
    /// without one.
    var isHostingTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
