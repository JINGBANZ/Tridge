import CoreData
import XCTest
@testable import Tridge

/// Launch, the bootstrap gate, and the account transition — the three places
/// where the wrong ordering would either show one account another's inventory
/// or pull a store out from under a running save.
@MainActor
final class AccountSessionCoordinatorTests: XCTestCase {
    private var baseDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var loader: StackLoader!
    private var identity: FakeAccountIdentity!
    private var monitor: StoreScopedSyncMonitor!
    private var coordinator: AccountSessionCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AccountSessionCoordinatorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "AccountSessionCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        coordinator = AccountSessionCoordinator(
            identity: identity, syncMonitor: monitor,
            barrier: BootstrapBarrierStore(defaults: defaults),
            activeHouseholds: ActiveHouseholdStore(defaults: defaults),
            makePersistence: loader.closure)
    }

    override func tearDown() async throws {
        await coordinator?.shutDown()
        coordinator = nil
        loader?.tearDownAll()
        // `removeSuite(named:)` only drops the suite from `standard`'s search
        // list, which this one was never in; the plist has to go explicitly.
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private static func scope(_ character: Character = "a") -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: character, count: 64))!
    }

    /// Puts a household in the account's private store before the coordinator
    /// opens it, which is what an existing validated cache looks like.
    @discardableResult
    private func seedExistingHousehold(
        scope: AccountScopeHash, name: String = "My Fridge",
        ownership: HouseholdOwnership = .owned, createdAt: Date = Date(),
        corrupt: Bool = false
    ) async throws -> UUID {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
        defer { controller.tearDown() }
        return try await insertHousehold(into: controller, name: name, ownership: ownership,
                                         createdAt: createdAt, corrupt: corrupt)
    }

    /// Writes through a stack that is already open, which is how a row would
    /// actually appear during an import — rather than opening a second
    /// coordinator on the same files.
    @discardableResult
    private func insertHousehold(
        into controller: PersistenceController, name: String,
        ownership: HouseholdOwnership = .owned, createdAt: Date = Date(),
        corrupt: Bool = false
    ) async throws -> UUID {
        let id = UUID()
        let store = ownership == .owned ? controller.privateStore : controller.sharedStore
        let context = controller.newWriterContext()
        try await context.perform {
            let household = HouseholdRecord(context: context)
            household.id = id
            household.name = corrupt ? "" : name
            household.initialInventoryEpochID = UUID()
            household.createdAt = createdAt
            household.modifiedAt = createdAt
            try StoreRouting.assign([household], to: store, in: context)
            try context.save()
        }
        return id
    }

    /// Emits the setup and import a store reports on its first successful sync.
    private func completeInitialSync(of storeIdentifier: String) {
        for kind in [SyncEventKind.setup, .importChanges] {
            let id = "\(storeIdentifier).\(kind)"
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                      kind: kind, isComplete: false))
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                      kind: kind, isComplete: true, succeeded: true))
        }
    }

    // MARK: - Launch

    func testAValidAccountOpensBothStoresAndBecomesReady() async throws {
        let seeded = try await seedExistingHousehold(scope: Self.scope())

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertEqual(coordinator.activeHouseholdID, seeded)
        XCTAssertEqual(coordinator.households.map(\.id), [seeded])
        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(session.context.accountScope, Self.scope())
        XCTAssertEqual(session.context.storeIdentifiers,
                       session.persistence.storeIdentifiers)
        XCTAssertEqual(session.context.storeIdentifiers.count, 2)
    }

    func testNoICloudAccountBlocksWithoutExposingAnyStore() async {
        identity.result = .failure(AccountIdentityError.unavailable(.noAccount))

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .iCloudAccountRequired(.noAccount))
        XCTAssertFalse(coordinator.launchState.isRetryable)
        XCTAssertNil(coordinator.session)
        XCTAssertTrue(loader.controllers.isEmpty, "a store opened without a validated account")
    }

    func testAnUndeterminedAccountIsRetryableRatherThanBlocking() async {
        identity.result = .failure(AccountIdentityError.lookupFailed(.couldNotDetermine))

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .iCloudAccountRequired(.couldNotDetermine))
        XCTAssertTrue(coordinator.launchState.isRetryable)
        XCTAssertNil(coordinator.session)
    }

    func testAStoreFailureIsRetryableAndExposesNeitherStore() async {
        loader.failure = PersistenceController.LoadError(diagnosticID: "test.7")

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .persistenceUnavailable(diagnosticID: "test.7"))
        XCTAssertTrue(coordinator.launchState.isRetryable)
        XCTAssertNil(coordinator.session)
    }

    func testRetryAfterAFailureOpensTheStack() async throws {
        loader.failure = PersistenceController.LoadError(diagnosticID: "test.7")
        await coordinator.start()
        XCTAssertNil(coordinator.session)

        loader.failure = nil
        try await seedExistingHousehold(scope: Self.scope())
        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertNotNil(coordinator.session)
    }

    // MARK: - Bootstrap gate

    func testAnEmptyCacheWaitsForItsFirstImportBeforeItMayBootstrap() async throws {
        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .finishingCloudSetup)
        // It clears itself when the import lands, so it offers no Retry:
        // restarting would discard the setup that already succeeded.
        XCTAssertFalse(coordinator.launchState.isRetryable)
        XCTAssertFalse(coordinator.hasCompletedInitialPrivateImport)

        let session = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: session.context.privateStoreIdentifier)

        await waitUntil("the bootstrap barrier to open") {
            self.coordinator.hasCompletedInitialPrivateImport
        }
        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertTrue(BootstrapBarrierStore(defaults: defaults).hasCompletedInitialImport(
            accountScope: session.context.accountScope,
            privateStoreIdentifier: session.context.privateStoreIdentifier))
    }

    /// The shared store's import says nothing about whether this account owns a
    /// household that is still arriving in the private one.
    func testTheSharedStoresImportDoesNotOpenTheBarrier() async throws {
        await coordinator.start()
        let session = try XCTUnwrap(coordinator.session)

        completeInitialSync(of: session.context.sharedStoreIdentifier)
        await Task.yield()

        XCTAssertFalse(coordinator.hasCompletedInitialPrivateImport)
        XCTAssertEqual(coordinator.launchState, .finishingCloudSetup)
    }

    func testAnExistingCacheRendersWithoutWaitingForAFreshImport() async throws {
        try await seedExistingHousehold(scope: Self.scope())

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertNotNil(coordinator.activeHouseholdID)
        XCTAssertFalse(coordinator.hasCompletedInitialPrivateImport,
                       "rendering a cache is not evidence that an import succeeded")
    }

    // MARK: - Active Household selection

    func testAnEmptyAccountCreatesMyFridgeOnceTheBarrierOpens() async throws {
        await coordinator.start()
        XCTAssertNil(coordinator.activeHouseholdID)

        let session = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: session.context.privateStoreIdentifier)
        await waitUntil("My Fridge to be created") { self.coordinator.activeHouseholdID != nil }

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertEqual(coordinator.households.count, 1)
        XCTAssertEqual(coordinator.households.first?.name, "My Fridge")
        XCTAssertEqual(coordinator.households.first?.ownership, .owned)
        XCTAssertEqual(coordinator.activeHouseholdID, coordinator.households.first?.id)
    }

    /// The whole point of the barrier: a Household that arrives in the first
    /// import is selected instead of being duplicated by a second `My Fridge`.
    func testAnImportedHouseholdIsSelectedInsteadOfCreatingADuplicate() async throws {
        await coordinator.start()
        XCTAssertEqual(coordinator.launchState, .finishingCloudSetup)
        let session = try XCTUnwrap(coordinator.session)

        // The import lands the account's existing Household before the barrier
        // opens, exactly as a real initial import would.
        let imported = try await insertHousehold(into: session.persistence, name: "Kitchen")
        completeInitialSync(of: session.context.privateStoreIdentifier)
        await waitUntil("the imported Household to be selected") {
            self.coordinator.activeHouseholdID != nil
        }

        XCTAssertEqual(coordinator.activeHouseholdID, imported)
        XCTAssertEqual(coordinator.households.map(\.name), ["Kitchen"])
    }

    func testTheOldestOwnedHouseholdWinsOverAReceivedOne() async throws {
        let older = Date(timeIntervalSince1970: 1_000)
        let owned = try await seedExistingHousehold(scope: Self.scope(), name: "Owned",
                                                    createdAt: older.addingTimeInterval(60))
        try await seedExistingHousehold(scope: Self.scope(), name: "Received",
                                        ownership: .received, createdAt: older)

        await coordinator.start()

        XCTAssertEqual(coordinator.activeHouseholdID, owned)
        XCTAssertEqual(Set(coordinator.households.map(\.ownership)), [.owned, .received])
    }

    func testAReceivedHouseholdIsSelectedWhenNoneIsOwned() async throws {
        let received = try await seedExistingHousehold(scope: Self.scope(), name: "Theirs",
                                                       ownership: .received)

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertEqual(coordinator.activeHouseholdID, received)
        XCTAssertEqual(coordinator.households.first?.ownership, .received)
    }

    func testASavedSelectionIsRestoredAndPersistedPerAccount() async throws {
        let first = try await seedExistingHousehold(scope: Self.scope(), name: "A",
                                                    createdAt: Date(timeIntervalSince1970: 10))
        let second = try await seedExistingHousehold(scope: Self.scope(), name: "B",
                                                     createdAt: Date(timeIntervalSince1970: 20))
        // Deterministic fallback picks the oldest owned one.
        await coordinator.start()
        XCTAssertEqual(coordinator.activeHouseholdID, first)

        ActiveHouseholdStore(defaults: defaults).save(second, for: Self.scope())
        await coordinator.start()
        XCTAssertEqual(coordinator.activeHouseholdID, second)

        // Another account's key never satisfies this one.
        XCTAssertNil(ActiveHouseholdStore(defaults: defaults).savedID(for: Self.scope("b")))
    }

    /// A household that was left, revoked, or deleted must not be restored
    /// from a stale default.
    func testAStaleSavedSelectionFallsBackToAnAccessibleHousehold() async throws {
        let accessible = try await seedExistingHousehold(scope: Self.scope())
        ActiveHouseholdStore(defaults: defaults).save(UUID(), for: Self.scope())

        await coordinator.start()

        XCTAssertEqual(coordinator.activeHouseholdID, accessible)
    }

    func testACorruptHouseholdIsOmittedRatherThanSelected() async throws {
        try await seedExistingHousehold(scope: Self.scope(), corrupt: true)
        let valid = try await seedExistingHousehold(scope: Self.scope(), name: "Valid")

        await coordinator.start()

        XCTAssertEqual(coordinator.households.map(\.id), [valid])
        XCTAssertEqual(coordinator.activeHouseholdID, valid)
    }

    func testARecordedMarkerSkipsTheBarrierOnTheNextLaunch() async throws {
        await coordinator.start()
        let first = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: first.context.privateStoreIdentifier)
        await waitUntil("the bootstrap barrier to open") {
            self.coordinator.hasCompletedInitialPrivateImport
        }

        await coordinator.start()

        XCTAssertEqual(coordinator.launchState, .ready)
        XCTAssertTrue(coordinator.hasCompletedInitialPrivateImport)
    }

    func testAnotherAccountsMarkerDoesNotSatisfyThisAccountsBarrier() async throws {
        let barrier = BootstrapBarrierStore(defaults: defaults)
        await coordinator.start()
        let session = try XCTUnwrap(coordinator.session)
        barrier.recordInitialImport(
            accountScope: Self.scope("b"),
            privateStoreIdentifier: session.context.privateStoreIdentifier)

        XCTAssertFalse(barrier.hasCompletedInitialImport(
            accountScope: session.context.accountScope,
            privateStoreIdentifier: session.context.privateStoreIdentifier))
        XCTAssertEqual(coordinator.launchState, .finishingCloudSetup)
    }

    // MARK: - Account transition

    func testAnAccountChangeDuringTheStoreLoadReleasesTheStoresItOpened() async throws {
        let gate = AsyncGate()
        loader.gate = { await gate.wait() }

        let starting = Task { await self.coordinator.start() }
        await waitUntil("the store load to begin") { gate.isWaiting }

        // The account changes while both descriptions are still loading.
        loader.gate = nil
        coordinator.accountDidChange()
        XCTAssertNil(coordinator.session, "the previous account stayed on screen")
        gate.open()
        await starting.value

        await waitUntil("the next account's session") { self.coordinator.session != nil }
        XCTAssertEqual(loader.controllers.count, 2)
        let abandoned = loader.controllers[0]
        XCTAssertTrue(abandoned.container.persistentStoreCoordinator.persistentStores.isEmpty,
                      "the abandoned generation kept its stores loaded")
        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(session.persistence.storeIdentifiers,
                       loader.controllers[1].storeIdentifiers)
    }

    func testRegisteredWorkFinishesBeforeItsStoresAreRemoved() async throws {
        await coordinator.start()
        let session = try XCTUnwrap(coordinator.session)
        let controller = session.persistence

        let started = AsyncGate()
        let sawLoadedStores = LockedBox(false)
        let running = Task {
            try? await self.coordinator.tasks.run(context: session.context) {
                started.open()
                // Stands in for a `context.perform` save: not cooperative, so
                // cancelling its task proves nothing.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume()
                    }
                }
                sawLoadedStores.value =
                    !controller.container.persistentStoreCoordinator.persistentStores.isEmpty
            }
        }
        await waitUntil("the registered operation to start") { started.isOpen }

        coordinator.accountDidChange()
        await waitUntil("the next account's session") { self.coordinator.session != nil }
        _ = await running.value

        XCTAssertTrue(sawLoadedStores.value,
                      "the stores were removed while a registered save was running")
        XCTAssertTrue(controller.container.persistentStoreCoordinator.persistentStores.isEmpty,
                      "the previous account's stores were never released")
    }

    func testAnAccountChangeClearsTheBarrierStateBeforeTheNextAccountLoads() async throws {
        await coordinator.start()
        let first = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: first.context.privateStoreIdentifier)
        await waitUntil("the bootstrap barrier to open") {
            self.coordinator.hasCompletedInitialPrivateImport
        }

        identity.result = .success(Self.scope("b"))
        coordinator.accountDidChange()

        XCTAssertFalse(coordinator.hasCompletedInitialPrivateImport)
        XCTAssertNil(coordinator.session)
        XCTAssertNil(coordinator.activeHouseholdID)
        XCTAssertTrue(coordinator.households.isEmpty)
        await waitUntil("the next account's session") { self.coordinator.session != nil }
        let second = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(second.context.accountScope, Self.scope("b"))
        XCTAssertNotEqual(second.context.generation, first.context.generation)
        // The previous account's marker never satisfies this one.
        XCTAssertFalse(coordinator.hasCompletedInitialPrivateImport)
        XCTAssertEqual(coordinator.launchState, .finishingCloudSetup)
    }

    func testShutDownReleasesTheStoresAndClearsTheSession() async throws {
        try await seedExistingHousehold(scope: Self.scope())
        await coordinator.start()
        let controller = try XCTUnwrap(coordinator.session).persistence

        await coordinator.shutDown()

        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.launchState, .preparing)
        XCTAssertTrue(controller.container.persistentStoreCoordinator.persistentStores.isEmpty)
    }
}

// MARK: - Fakes

/// A latch a test can hold a load open on, and observe that it is being held.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { lock.withLock { opened } }
    var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        let alreadyOpen: Bool = lock.withLock { opened }
        guard !alreadyOpen else { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
