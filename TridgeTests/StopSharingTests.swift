import CloudKit
import CoreData
import XCTest
@testable import Tridge

/// Stop Sharing & Keep My Fridge: the one transition that destroys shared data
/// on purpose, so every step has to be provable before the next one runs.
@MainActor
final class StopSharingTests: XCTestCase {
    private var baseDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var loader: StackLoader!
    private var identity: FakeAccountIdentity!
    private var monitor: StoreScopedSyncMonitor!
    private var notifications: FakeNotificationCenter!
    private var sharing: FakeHouseholdSharing!
    private var coordinator: AccountSessionCoordinator!

    private static func scope() -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: "a", count: 64))!
    }

    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StopSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "StopSharingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        notifications = FakeNotificationCenter()
        sharing = FakeHouseholdSharing()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        await coordinator?.shutDown()
        coordinator = nil
        loader?.tearDownAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    /// A second coordinator over the same defaults and stores is what a relaunch
    /// looks like — which is how every interrupted phase is exercised.
    private func makeCoordinator() -> AccountSessionCoordinator {
        let sharing = self.sharing!
        return AccountSessionCoordinator(
            identity: identity, syncMonitor: monitor,
            reminders: ReminderReconciler(center: notifications, defaults: defaults),
            defaults: defaults,
            barrier: BootstrapBarrierStore(defaults: defaults),
            activeHouseholds: ActiveHouseholdStore(defaults: defaults),
            upgrade: LegacyInventoryUpgrade(archive: FakeLegacyArchive(rows: [], exists: false),
                                            markers: UpgradeMarkers(defaults: defaults),
                                            effects: RecordingLegacyEffects()),
            invitations: ShareInvitationRouter(),
            makePersistence: loader.closure,
            makeSharing: { _ in sharing })
    }

    // MARK: - Seeding

    @discardableResult
    private func insertHousehold(into controller: PersistenceController, name: String,
                                 ownership: HouseholdOwnership = .owned) throws -> UUID {
        let context = controller.newWriterContext()
        let store = ownership == .owned ? controller.privateStore : controller.sharedStore
        var result: Result<UUID, Error>!
        context.performAndWait {
            result = Result {
                let household = HouseholdRecord(context: context)
                let id = UUID()
                household.id = id
                household.name = name
                household.initialInventoryEpochID = UUID()
                household.createdAt = Date()
                household.modifiedAt = household.createdAt
                try StoreRouting.assign([household], to: store, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    /// A shared owned fridge with a few things in it, settled and ready to stop.
    private func startWithSharedFridge(name: String = "Home") async throws -> UUID {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let id = try insertHousehold(into: controller, name: name)
        controller.tearDown()

        sharing.sharedHouseholds = [id]
        await coordinator.start()
        await waitUntil("the fridge is selected") { self.coordinator.activeHouseholdID == id }
        await waitUntil("share state is applied") {
            self.coordinator.activeHousehold?.isShared == true
        }
        settleSync()
        return id
    }

    /// Emits the setup and import that make both stores report up to date, which
    /// is the precondition every destructive share action requires.
    private func settleSync() {
        guard let context = coordinator.session?.context else { return }
        for storeIdentifier in [context.privateStoreIdentifier, context.sharedStoreIdentifier] {
            for kind in [SyncEventKind.setup, .importChanges] {
                let id = "\(storeIdentifier).\(kind)"
                monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                          kind: kind, isComplete: false))
                monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                          kind: kind, isComplete: true, succeeded: true))
            }
        }
    }

    private func addItems(_ rows: [(name: String, quantity: Int64)]) async throws {
        let session = try XCTUnwrap(coordinator.inventory)
        let drafts = rows.map { row in
            PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: row.name,
                          quantity: row.quantity, artKey: ItemID.milk.rawValue, storage: .fridge,
                          purchaseDay: Self.today, expiryDay: Self.today.adding(days: 6)!,
                          expirySource: .llmEstimate, explicitMetadataFields: [])
        }
        let saved = await session.addReviewedRows(drafts)
        XCTAssertTrue(saved)
    }

    private struct StoredItem {
        let name: String
        let quantity: Int64
        let reasons: [String]
        let epochs: Set<UUID>
    }

    private struct StoredHousehold {
        let id: UUID
        let items: [StoredItem]
        let clearCount: Int
        let claimCount: Int
    }

    private func storedHouseholds() async throws -> [StoredHousehold] {
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let context = controller.newReaderContext()
        return await context.perform {
            ((try? context.fetch(HouseholdRecord.fetchRequest())) ?? []).compactMap { household in
                guard let id = household.id else { return nil }
                let items = household.items.compactMap { item -> StoredItem? in
                    guard let name = item.name, let raw = item.inventoryEpochContextRaw,
                          let epochs = InventoryEpochCodec.decode(raw) else { return nil }
                    let events = item.stockChanges
                    return StoredItem(name: name,
                                      quantity: events.reduce(Int64(0)) { $0 + $1.delta },
                                      reasons: events.compactMap(\.reasonRaw).sorted(),
                                      epochs: epochs)
                }
                .sorted { $0.name < $1.name }
                return StoredHousehold(id: id, items: items,
                                       clearCount: household.clearEvents.count,
                                       claimCount: household.itemMerges.count)
            }
        }
    }

    // MARK: - Preconditions

    func testStopIsRefusedForAReceivedHousehold() async throws {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        _ = try insertHousehold(into: controller, name: "Home")
        let received = try insertHousehold(into: controller, name: "Theirs", ownership: .received)
        controller.tearDown()
        sharing.sharedHouseholds = [received]
        await coordinator.start()
        await waitUntil("both fridges are listed") { self.coordinator.households.count == 2 }
        settleSync()

        let stopped = await coordinator.stopSharing(received)

        XCTAssertFalse(stopped)
        XCTAssertEqual(coordinator.householdFailure?.reason, .notOwner)
        XCTAssertEqual(sharing.purgedHouseholds, [])
    }

    func testStopIsRefusedUntilSyncHasSettled() async throws {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let id = try insertHousehold(into: controller, name: "Home")
        controller.tearDown()
        sharing.sharedHouseholds = [id]
        await coordinator.start()
        await waitUntil("share state is applied") {
            self.coordinator.activeHousehold?.isShared == true
        }
        // No sync events emitted, so the session is still "syncing".
        XCTAssertFalse(coordinator.canRunDestructiveShareAction)

        let stopped = await coordinator.stopSharing(id)

        XCTAssertFalse(stopped)
        XCTAssertEqual(coordinator.householdFailure?.reason, .unavailable)
        XCTAssertEqual(sharing.purgedHouseholds, [], "nothing is purged before it settles")
    }

    // MARK: - The copy

    func testTheCopyKeepsOneRowPerActiveGroupWithOnePreservedOperation() async throws {
        let source = try await startWithSharedFridge(name: "Home")
        try await addItems([("Milk", 2), ("Eggs", 6)])
        // A group consumed to zero is not part of what the owner can see.
        let session = try XCTUnwrap(coordinator.inventory)
        let eggs = try XCTUnwrap(session.items.first { $0.name == "Eggs" })
        for _ in 0..<6 { _ = await session.eatOne(eggs.id) }
        await waitUntil("eggs are gone") { session.items.count == 1 }

        let stopped = await coordinator.stopSharing(source)
        XCTAssertTrue(stopped)

        let households = try await storedHouseholds()
        XCTAssertEqual(households.count, 1, "the source graph is gone, the copy remains")
        let copy = try XCTUnwrap(households.first)
        XCTAssertNotEqual(copy.id, source)
        XCTAssertEqual(copy.items.map(\.name), ["Milk"], "zero groups are not copied")
        XCTAssertEqual(copy.items.first?.quantity, 2, "the visible quantity is preserved")
        XCTAssertEqual(copy.items.first?.reasons, [StockReason.preserved.rawValue],
                       "one fresh operation, not the old history")
        XCTAssertEqual(copy.clearCount, 0, "prior clear epochs are not copied")
        XCTAssertEqual(copy.claimCount, 0, "merge claims are not copied")
    }

    func testTheCopyIsStampedIntoItsOwnFreshEpoch() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])

        _ = await coordinator.stopSharing(source)

        let copy = try XCTUnwrap(try await storedHouseholds().first)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let context = controller.newReaderContext()
        let initialEpoch: UUID? = await context.perform {
            let request = HouseholdRecord.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", copy.id as NSUUID)
            return (try? context.fetch(request).first)?.initialInventoryEpochID
        }
        XCTAssertEqual(copy.items.first?.epochs, Set([try XCTUnwrap(initialEpoch)]),
                       "the copy starts its own causal history")
    }

    func testTheCopyBecomesTheActiveFridge() async throws {
        let source = try await startWithSharedFridge(name: "Home")
        try await addItems([("Milk", 1)])

        _ = await coordinator.stopSharing(source)

        let copyID = try XCTUnwrap(try await storedHouseholds().first?.id)
        XCTAssertEqual(coordinator.activeHouseholdID, copyID)
        XCTAssertEqual(coordinator.activeHousehold?.name, "Home")
        XCTAssertEqual(ActiveHouseholdStore(defaults: defaults).savedID(for: Self.scope()), copyID)
        await waitUntil("inventory follows the copy") {
            self.coordinator.inventory?.householdID == copyID
                && self.coordinator.inventory?.items.map(\.name) == ["Milk"]
        }
    }

    func testTheSourceZoneIsPurgedAndItsLocalGraphVerifiedAbsent() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])

        _ = await coordinator.stopSharing(source)

        XCTAssertEqual(sharing.purgedHouseholds, [source])
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(source)
        XCTAssertFalse(stillThere)
    }

    // MARK: - Never twice, never early

    func testAFailedCopyNeverPurgesTheSource() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])

        // The source disappears underneath the transition, so the copy has
        // nothing to read and fails before it inserts anything.
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        try await controller.removeLocalGraph(of: source)

        let stopped = await coordinator.stopSharing(source)

        XCTAssertFalse(stopped)
        XCTAssertEqual(sharing.purgedHouseholds, [], "a purge never precedes a verified copy")
    }

    func testATransitionInterruptedAfterTheCopyResumesWithoutCopyingAgain() async throws {
        let source = try await startWithSharedFridge(name: "Home")
        try await addItems([("Milk", 2)])
        // The purge fails, so the transition is left recorded at purgePending
        // with the copy already saved and verified.
        sharing.purgeFailure = CKError(.networkFailure)
        let stopped = await coordinator.stopSharing(source)
        XCTAssertFalse(stopped)
        XCTAssertEqual(coordinator.pendingLifecycleTransition?.phase, .purgePending)
        XCTAssertFalse(coordinator.households.contains { $0.id == source },
                       "the source is suppressed while cleanup is outstanding")

        // Relaunch.
        await coordinator.shutDown()
        coordinator = makeCoordinator()
        await coordinator.start()
        await waitUntil("the transition finishes") {
            self.coordinator.pendingLifecycleTransition == nil
        }

        let households = try await storedHouseholds()
        XCTAssertEqual(households.count, 1, "exactly one copy, however many attempts")
        XCTAssertEqual(households.first?.items.map(\.name), ["Milk"])
        XCTAssertEqual(households.first?.items.first?.quantity, 2)
        XCTAssertEqual(sharing.purgedHouseholds, [source],
                       "the purge is the only step that ran again")
    }

    func testAnAlreadyMissingZoneStillCompletesThroughLocalCleanup() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])
        sharing.missingZones = [source]

        let stopped = await coordinator.stopSharing(source)

        XCTAssertTrue(stopped)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(source)
        XCTAssertFalse(stillThere, "a missing remote zone is not the same as a clean device")
    }

    func testTheTransitionRecordIsClearedOnlyWhenItIsFinished() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])
        let store = LifecycleTransitionStore(accountScope: Self.scope(), defaults: defaults)

        sharing.purgeFailure = CKError(.networkFailure)
        _ = await coordinator.stopSharing(source)
        XCTAssertEqual(store.current()?.phase, .purgePending)

        _ = await coordinator.stopSharing(source)
        XCTAssertNil(store.current(), "the record goes only once the purge is done")
    }

    // MARK: - Local effects

    func testStoppingRetiresTheSourcesReminders() async throws {
        let source = try await startWithSharedFridge()
        try await addItems([("Milk", 1)])
        await waitUntil("the source has reminders") {
            self.notifications.pending.contains { $0.identifier.contains(source.uuidString) }
        }

        _ = await coordinator.stopSharing(source)

        await waitUntil("no reminder still names the source fridge") {
            self.notifications.pending.allSatisfy { !$0.identifier.contains(source.uuidString) }
        }
    }
}
