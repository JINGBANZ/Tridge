import XCTest
@testable import FridgeCore

/// The store boundary is what makes a sync label trustworthy: a completion that
/// belongs to another account's store must never settle this session's state.
final class SyncSessionReducerTests: XCTestCase {
    private let privateStore = "private-store"
    private let sharedStore = "shared-store"
    private let otherStore = "other-account-store"

    private func start(_ id: String, _ store: String, _ kind: SyncEventKind) -> SyncEvent {
        SyncEvent(identifier: id, storeIdentifier: store, kind: kind, isComplete: false)
    }

    private func success(_ id: String, _ store: String, _ kind: SyncEventKind) -> SyncEvent {
        SyncEvent(identifier: id, storeIdentifier: store, kind: kind, isComplete: true,
                  succeeded: true)
    }

    private func failure(_ id: String, _ store: String, _ kind: SyncEventKind,
                         transient: Bool = false) -> SyncEvent {
        SyncEvent(identifier: id, storeIdentifier: store, kind: kind, isComplete: true,
                  succeeded: false, isTransientFailure: transient)
    }

    /// Drives both stores through setup and import so the session is settled.
    private func settledSession() -> SyncSessionReducer {
        var reducer = SyncSessionReducer()
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        for store in [privateStore, sharedStore] {
            for kind in [SyncEventKind.setup, .importChanges] {
                let id = "\(store).\(kind)"
                reducer.record(start(id, store, kind))
                reducer.record(success(id, store, kind))
            }
        }
        return reducer
    }

    // MARK: - Buffering and activation

    func testEventsEmittedBeforeActivationReplayAfterIt() {
        var reducer = SyncSessionReducer()
        reducer.record(start("s1", privateStore, .setup))
        reducer.record(success("s1", privateStore, .setup))
        reducer.record(start("i1", privateStore, .importChanges))
        reducer.record(success("i1", privateStore, .importChanges))

        XCTAssertFalse(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))

        reducer.activate(storeIdentifiers: [privateStore, sharedStore])

        XCTAssertTrue(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))
    }

    func testActivationDiscardsBufferedEventsForOtherStores() {
        var reducer = SyncSessionReducer()
        reducer.record(start("s1", otherStore, .setup))
        reducer.record(success("s1", otherStore, .setup))
        reducer.record(start("i1", otherStore, .importChanges))
        reducer.record(success("i1", otherStore, .importChanges))

        reducer.activate(storeIdentifiers: [privateStore, sharedStore])

        XCTAssertFalse(reducer.hasCompletedInitialImport(storeIdentifier: otherStore))
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    func testLiveEventsForOtherStoresAreIgnored() {
        var reducer = settledSession()
        reducer.record(start("x", otherStore, .importChanges))
        reducer.record(failure("x", otherStore, .importChanges))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .upToDate)
    }

    /// Account A's completion arriving while account B is already active: B
    /// never accepted the start, so the completion cannot settle B's state.
    func testCompletionWithoutAnAcceptedStartIsIgnored() {
        var reducer = SyncSessionReducer()
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        reducer.record(success("stale", privateStore, .importChanges))

        XCTAssertFalse(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))
    }

    /// A start buffered for a store that never opened is dropped, so its later
    /// live completion has nothing to match.
    func testCompletionOfADiscardedBufferedStartIsIgnored() {
        var reducer = SyncSessionReducer()
        reducer.record(start("i1", otherStore, .importChanges))
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        reducer.record(success("i1", otherStore, .importChanges))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    func testActivationIsIdempotentAndDoesNotWidenTheStoreSet() {
        var reducer = settledSession()
        reducer.activate(storeIdentifiers: [otherStore])

        reducer.record(start("x", otherStore, .importChanges))
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .upToDate)
    }

    // MARK: - Status precedence

    func testUnavailableAccountOutranksEverythingElse() {
        let reducer = settledSession()
        XCTAssertEqual(reducer.status(account: .unavailable, isNetworkReachable: true),
                       .needsAttention)
    }

    func testPermanentFailureNeedsAttentionEvenWhenOffline() {
        var reducer = settledSession()
        reducer.record(start("e1", privateStore, .exportChanges))
        reducer.record(failure("e1", privateStore, .exportChanges))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: false),
                       .needsAttention)
    }

    func testValidatedAccountWithoutNetworkIsOffline() {
        let reducer = settledSession()
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: false), .offline)
    }

    func testWorkInProgressIsSyncing() {
        var reducer = settledSession()
        reducer.record(start("e1", privateStore, .exportChanges))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    /// A retried failure is unsettled rather than broken.
    func testTransientFailureWithNetworkBackIsSyncingNotUpToDate() {
        var reducer = settledSession()
        reducer.record(start("e1", privateStore, .exportChanges))
        reducer.record(failure("e1", privateStore, .exportChanges, transient: true))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    func testASucceedingRetryClearsAnEarlierFailure() {
        var reducer = settledSession()
        reducer.record(start("e1", privateStore, .exportChanges))
        reducer.record(failure("e1", privateStore, .exportChanges))
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true),
                       .needsAttention)

        reducer.record(start("e2", privateStore, .exportChanges))
        reducer.record(success("e2", privateStore, .exportChanges))

        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .upToDate)
    }

    func testBothStoresMustFinishSetupAndImportBeforeUpToDate() {
        var reducer = SyncSessionReducer()
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        for kind in [SyncEventKind.setup, .importChanges] {
            reducer.record(start("p.\(kind)", privateStore, kind))
            reducer.record(success("p.\(kind)", privateStore, kind))
        }

        XCTAssertTrue(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    func testAnUnactivatedSessionIsSyncingRatherThanUpToDate() {
        let reducer = SyncSessionReducer()
        XCTAssertEqual(reducer.status(account: .validated, isNetworkReachable: true), .syncing)
    }

    // MARK: - Bootstrap barrier

    func testImportWithoutSetupDoesNotOpenTheBarrier() {
        var reducer = SyncSessionReducer()
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        reducer.record(start("i1", privateStore, .importChanges))
        reducer.record(success("i1", privateStore, .importChanges))

        XCTAssertFalse(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))
    }

    func testAFailedImportDoesNotOpenTheBarrier() {
        var reducer = SyncSessionReducer()
        reducer.activate(storeIdentifiers: [privateStore, sharedStore])
        reducer.record(start("setup", privateStore, .setup))
        reducer.record(success("setup", privateStore, .setup))
        reducer.record(start("import", privateStore, .importChanges))
        reducer.record(failure("import", privateStore, .importChanges, transient: true))

        XCTAssertFalse(reducer.hasCompletedInitialImport(storeIdentifier: privateStore))
    }
}
