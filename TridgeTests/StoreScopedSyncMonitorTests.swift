import XCTest
@testable import Tridge

/// The monitor's whole job is to refuse events it cannot prove belong to the
/// current account's stores, so every test here is an attempt to smuggle one in.
@MainActor
final class StoreScopedSyncMonitorTests: XCTestCase {
    private let privateStore = "private-store"
    private let sharedStore = "shared-store"
    private let otherStore = "other-account-store"

    private var monitor: StoreScopedSyncMonitor!

    override func setUp() {
        super.setUp()
        monitor = StoreScopedSyncMonitor()
    }

    override func tearDown() {
        monitor = nil
        super.tearDown()
    }

    private func start(_ id: String, _ store: String, _ kind: SyncEventKind) -> SyncEvent {
        SyncEvent(identifier: id, storeIdentifier: store, kind: kind, isComplete: false)
    }

    private func success(_ id: String, _ store: String, _ kind: SyncEventKind) -> SyncEvent {
        SyncEvent(identifier: id, storeIdentifier: store, kind: kind, isComplete: true,
                  succeeded: true)
    }

    /// Emits the setup and import a store reports on its first successful sync.
    private func completeInitialSync(_ store: String, prefix: String = "") {
        for kind in [SyncEventKind.setup, .importChanges] {
            let id = "\(prefix)\(store).\(kind)"
            monitor.receive(start(id, store, kind))
            monitor.receive(success(id, store, kind))
        }
    }

    // MARK: - Buffering across the store load

    /// Setup and import can both start and finish while `loadPersistentStores`
    /// is still running, which is exactly why observation starts first.
    func testEventsEmittedBeforeActivationAreReplayedAfterIt() {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        completeInitialSync(privateStore)

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: generation,
                                                         storeIdentifier: privateStore))

        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        XCTAssertTrue(monitor.hasCompletedInitialImport(generation: generation,
                                                        storeIdentifier: privateStore))
    }

    func testBufferedEventsForAnotherStoreAreDiscardedAtActivation() {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        completeInitialSync(otherStore)

        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: generation,
                                                         storeIdentifier: otherStore))
    }

    func testLiveEventsForAnotherStoreAreIgnored() {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])
        completeInitialSync(otherStore)

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: generation,
                                                         storeIdentifier: otherStore))
    }

    func testEventsBeforeAnySessionAreIgnored() {
        completeInitialSync(privateStore)
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: generation,
                                                         storeIdentifier: privateStore))
    }

    // MARK: - Generation isolation

    /// Account A's import completes after account B activated the same store
    /// path. B never accepted the start, so the completion settles nothing.
    func testACompletionWhoseStartBelongsToAPriorGenerationIsIgnored() {
        let first = AccountGeneration()
        monitor.prepareSession(generation: first)
        monitor.activateSession(generation: first, storeIdentifiers: [privateStore, sharedStore])
        monitor.receive(start("setup", privateStore, .setup))
        monitor.receive(start("import", privateStore, .importChanges))
        monitor.endSession(generation: first)

        let second = AccountGeneration()
        monitor.prepareSession(generation: second)
        monitor.activateSession(generation: second, storeIdentifiers: [privateStore, sharedStore])
        monitor.receive(success("setup", privateStore, .setup))
        monitor.receive(success("import", privateStore, .importChanges))

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: second,
                                                         storeIdentifier: privateStore))
    }

    /// The same completion arriving while the next account is still preparing:
    /// it is buffered, then discarded because that generation never saw a start.
    func testACompletionArrivingWhileTheNextAccountPreparesIsIgnored() {
        let first = AccountGeneration()
        monitor.prepareSession(generation: first)
        monitor.activateSession(generation: first, storeIdentifiers: [privateStore, sharedStore])
        monitor.receive(start("setup", privateStore, .setup))
        monitor.endSession(generation: first)

        let second = AccountGeneration()
        monitor.prepareSession(generation: second)
        monitor.receive(success("setup", privateStore, .setup))
        monitor.activateSession(generation: second, storeIdentifiers: [privateStore, sharedStore])

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: second,
                                                         storeIdentifier: privateStore))
    }

    func testAnotherGenerationCannotActivateOrEndThisSession() {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)

        monitor.activateSession(generation: AccountGeneration(),
                                storeIdentifiers: [privateStore, sharedStore])
        completeInitialSync(privateStore)
        // Still buffered, because the impostor activation was rejected.
        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: generation,
                                                         storeIdentifier: privateStore))

        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])
        XCTAssertTrue(monitor.hasCompletedInitialImport(generation: generation,
                                                        storeIdentifier: privateStore))

        monitor.endSession(generation: AccountGeneration())
        XCTAssertTrue(monitor.hasCompletedInitialImport(generation: generation,
                                                        storeIdentifier: privateStore))
    }

    func testTheBarrierIsNeverReportedForAnotherGeneration() {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])
        completeInitialSync(privateStore)

        XCTAssertFalse(monitor.hasCompletedInitialImport(generation: AccountGeneration(),
                                                         storeIdentifier: privateStore))
    }

    // MARK: - Waiting for the barrier

    func testWaitingResolvesWhenTheInitialImportSucceeds() async {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        let waiting = Task { @MainActor in
            await self.monitor.waitForInitialImport(generation: generation,
                                                    storeIdentifier: self.privateStore)
        }
        await Task.yield()
        completeInitialSync(privateStore)

        let opened = await waiting.value
        XCTAssertTrue(opened)
    }

    func testWaitingResolvesFalseWhenTheSessionEnds() async {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        let waiting = Task { @MainActor in
            await self.monitor.waitForInitialImport(generation: generation,
                                                    storeIdentifier: self.privateStore)
        }
        await Task.yield()
        monitor.endSession(generation: generation)

        let opened = await waiting.value
        XCTAssertFalse(opened)
    }

    func testWaitingResolvesFalseWhenCancelled() async {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        let waiting = Task { @MainActor in
            await self.monitor.waitForInitialImport(generation: generation,
                                                    storeIdentifier: self.privateStore)
        }
        await Task.yield()
        waiting.cancel()

        let opened = await waiting.value
        XCTAssertFalse(opened)
    }

    func testWaitingForAnotherGenerationResolvesFalseImmediately() async {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])

        let opened = await monitor.waitForInitialImport(generation: AccountGeneration(),
                                                        storeIdentifier: privateStore)
        XCTAssertFalse(opened)
    }

    func testAnAlreadyOpenBarrierDoesNotWait() async {
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation,
                                storeIdentifiers: [privateStore, sharedStore])
        completeInitialSync(privateStore)

        let opened = await monitor.waitForInitialImport(generation: generation,
                                                        storeIdentifier: privateStore)
        XCTAssertTrue(opened)
    }

    // MARK: - Status

    func testAnUnavailableAccountNeedsAttention() {
        monitor.updateAccountState(.unavailable)
        XCTAssertEqual(monitor.currentStatus, .needsAttention)

        monitor.updateAccountState(.validated)
        XCTAssertNotEqual(monitor.currentStatus, .needsAttention)
    }
}
