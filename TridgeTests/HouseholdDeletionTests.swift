import CloudKit
import CoreData
import XCTest
@testable import Tridge

/// Owner deletion, where the hard part is not deleting but *knowing*: a local
/// Core Data delete only queues an export, so "deleted from iCloud" has to be
/// read back rather than assumed.
@MainActor
final class HouseholdDeletionTests: XCTestCase {
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

    private static let record = CapturedCloudKitRecord(recordName: "record-1",
                                                       zoneName: "zone-1",
                                                       zoneOwnerName: "__defaultOwner__")

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdDeletionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "HouseholdDeletionTests-\(UUID().uuidString)"
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
                                 createdAt: Date) throws -> UUID {
        let context = controller.newWriterContext()
        var result: Result<UUID, Error>!
        context.performAndWait {
            result = Result {
                let household = HouseholdRecord(context: context)
                let id = UUID()
                household.id = id
                household.name = name
                household.initialInventoryEpochID = UUID()
                household.createdAt = createdAt
                household.modifiedAt = createdAt
                try StoreRouting.assign([household], to: controller.privateStore, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    /// Two owned fridges, the second active — so a deletion has somewhere
    /// deterministic to fall back to.
    private func startWithTwoFridges() async throws -> (keep: UUID, target: UUID) {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let keep = try insertHousehold(into: controller, name: "Home",
                                       createdAt: Date(timeIntervalSince1970: 1))
        let target = try insertHousehold(into: controller, name: "Beach House",
                                         createdAt: Date(timeIntervalSince1970: 2))
        controller.tearDown()
        await coordinator.start()
        await waitUntil("both fridges are listed") { self.coordinator.households.count == 2 }
        coordinator.selectHousehold(target)
        await waitUntil("the target is active") { self.coordinator.activeHouseholdID == target }
        await settleSync()
        return (keep, target)
    }

    private func settleSync() async {
        guard let context = coordinator.session?.context else { return }
        for storeIdentifier in [context.privateStoreIdentifier, context.sharedStoreIdentifier] {
            for kind in [SyncEventKind.setup, .importChanges] {
                emit(kind, store: storeIdentifier)
            }
        }
        // The mirror is fed by an AsyncStream, so the status settles a turn
        // later than the events that settle it.
        await waitUntil("both stores report up to date") {
            self.coordinator.canRunDestructiveShareAction
        }
    }

    /// One complete successful event for a store.
    private func emit(_ kind: SyncEventKind, store: String, id: String = UUID().uuidString) {
        monitor.receive(SyncEvent(identifier: id, storeIdentifier: store, kind: kind,
                                  isComplete: false))
        monitor.receive(SyncEvent(identifier: id, storeIdentifier: store, kind: kind,
                                  isComplete: true, succeeded: true))
    }

    private func emitPrivateExport() {
        guard let context = coordinator.session?.context else { return }
        emit(.exportChanges, store: context.privateStoreIdentifier)
    }

    /// Emits private-store exports until the absence check has run.
    ///
    /// The check registers its export waiter on its own task, so a single
    /// emission can land before anything is listening. Repeating is harmless —
    /// the waiter resolves on the first export it actually sees.
    private func awaitAbsenceCheck(_ count: Int = 1) async {
        await waitUntil("the absence check runs") {
            self.emitPrivateExport()
            return self.sharing.confirmCount >= count
        }
    }

    // MARK: - Which action is offered

    func testDeletingAReceivedHouseholdIsRefused() async throws {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        _ = try insertHousehold(into: controller, name: "Home",
                                createdAt: Date(timeIntervalSince1970: 1))
        let received = try {
            let context = controller.newWriterContext()
            var result: Result<UUID, Error>!
            context.performAndWait {
                result = Result {
                    let household = HouseholdRecord(context: context)
                    let id = UUID()
                    household.id = id
                    household.name = "Theirs"
                    household.initialInventoryEpochID = UUID()
                    household.createdAt = Date(timeIntervalSince1970: 2)
                    household.modifiedAt = household.createdAt
                    try StoreRouting.assign([household], to: controller.sharedStore, in: context)
                    try context.save()
                    return id
                }
            }
            return try result.get()
        }()
        controller.tearDown()
        await coordinator.start()
        await waitUntil("both fridges are listed") { self.coordinator.households.count == 2 }
        await settleSync()

        let deleted = await coordinator.deleteHousehold(received)

        XCTAssertFalse(deleted)
        XCTAssertEqual(coordinator.householdFailure?.reason, .notOwner)
    }

    func testDeletionIsRefusedUntilSyncHasSettled() async throws {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let id = try insertHousehold(into: controller, name: "Home", createdAt: Date())
        controller.tearDown()
        await coordinator.start()
        await waitUntil("the fridge is selected") { self.coordinator.activeHouseholdID == id }

        let deleted = await coordinator.deleteHousehold(id)

        XCTAssertFalse(deleted)
        XCTAssertEqual(coordinator.householdFailure?.reason, .unavailable)
    }

    // MARK: - Unshared deletion, verified

    func testAnUnmirroredFridgeCompletesOnTheVerifiedLocalSave() async throws {
        let fridges = try await startWithTwoFridges()
        // No captured records: this fridge was never mirrored.

        let deleted = await coordinator.deleteHousehold(fridges.target)

        XCTAssertTrue(deleted)
        await waitUntil("the deletion completes") {
            self.coordinator.pendingLifecycleTransition == nil
        }
        XCTAssertEqual(sharing.confirmCount, 0, "there is nothing to read back")
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.keep)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.target)
        XCTAssertFalse(stillThere)
    }

    func testAMirroredFridgeStaysPendingUntilEveryRecordIsConfirmedAbsent() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.recordsByHousehold = [fridges.target: [Self.record]]
        sharing.recordsStillPresent = [Self.record.recordName]

        let deleted = await coordinator.deleteHousehold(fridges.target)

        XCTAssertTrue(deleted, "the local half is done as soon as it is done")
        XCTAssertEqual(coordinator.pendingLifecycleTransition?.phase, .privateDeleteAwaitingCloud)
        // The fallback is already available; only the iCloud claim waits.
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.keep)
        await awaitAbsenceCheck()

        XCTAssertEqual(coordinator.pendingLifecycleTransition?.phase, .privateDeleteAwaitingCloud,
                       "a record that is still there keeps it pending")
        XCTAssertEqual(
            LifecycleTransitionStore(accountScope: Self.scope(), defaults: defaults)
                .current()?.phase,
            .privateDeleteAwaitingCloud, "the pending check survives termination")
    }

    func testARelaunchResumesThePendingAbsenceCheckAndFinishes() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.recordsByHousehold = [fridges.target: [Self.record]]
        sharing.recordsStillPresent = [Self.record.recordName]

        _ = await coordinator.deleteHousehold(fridges.target)
        await awaitAbsenceCheck()

        // Relaunch, with the record now really gone.
        sharing.recordsStillPresent = []
        await coordinator.shutDown()
        coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertEqual(coordinator.pendingLifecycleTransition?.phase,
                       .privateDeleteAwaitingCloud, "the resumed check is waiting for an export")

        await waitUntil("the deletion completes") {
            self.emitPrivateExport()
            return self.coordinator.pendingLifecycleTransition == nil
        }
        XCTAssertNil(LifecycleTransitionStore(accountScope: Self.scope(),
                                              defaults: defaults).current())
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.keep)
    }

    func testAnExportAloneIsNotTreatedAsConfirmation() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.recordsByHousehold = [fridges.target: [Self.record]]
        sharing.recordsStillPresent = [Self.record.recordName]

        _ = await coordinator.deleteHousehold(fridges.target)
        await awaitAbsenceCheck()

        XCTAssertNotNil(coordinator.pendingLifecycleTransition,
                        "an export says work was sent, not that these records are gone")
    }

    /// The check waits on an export, which can take as long as CloudKit takes.
    /// Everything that is not a second destructive action stays usable.
    func testAPendingCloudCheckDoesNotFreezeTheRestOfTheScreen() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.recordsByHousehold = [fridges.target: [Self.record]]
        sharing.recordsStillPresent = [Self.record.recordName]

        _ = await coordinator.deleteHousehold(fridges.target)

        XCTAssertFalse(coordinator.isHouseholdActionInFlight)
        let exported = await coordinator.exportHousehold(fridges.keep)
        XCTAssertTrue(exported)
        coordinator.clearExportedDocument()
        XCTAssertFalse(coordinator.canRunDestructiveShareAction,
                       "but a second destructive action still cannot start")
    }

    // MARK: - Shared deletion

    func testDeletingASharedFridgePurgesWithoutCopying() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.sharedHouseholds = [fridges.target]
        coordinator.refreshOnForeground()
        await waitUntil("share state is applied") {
            self.coordinator.households.first { $0.id == fridges.target }?.isShared == true
        }
        let before = coordinator.households.count

        let deleted = await coordinator.deleteHousehold(fridges.target)

        XCTAssertTrue(deleted)
        XCTAssertEqual(sharing.purgedHouseholds, [fridges.target])
        XCTAssertEqual(sharing.confirmCount, 0, "the shared path is a purge, not a read-back")
        XCTAssertEqual(coordinator.households.count, before - 1,
                       "no copy is made for the owner")
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.target)
        XCTAssertFalse(stillThere)
    }

    func testAnAlreadyMissingSharedZoneStillRequiresVerifiedLocalCleanup() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.sharedHouseholds = [fridges.target]
        sharing.missingZones = [fridges.target]
        coordinator.refreshOnForeground()
        await waitUntil("share state is applied") {
            self.coordinator.households.first { $0.id == fridges.target }?.isShared == true
        }

        let deleted = await coordinator.deleteHousehold(fridges.target)

        XCTAssertTrue(deleted)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.target)
        XCTAssertFalse(stillThere)
    }

    func testAFailedSharedPurgeKeepsTheFridgeHiddenAndRetryable() async throws {
        let fridges = try await startWithTwoFridges()
        sharing.sharedHouseholds = [fridges.target]
        coordinator.refreshOnForeground()
        await waitUntil("share state is applied") {
            self.coordinator.households.first { $0.id == fridges.target }?.isShared == true
        }
        sharing.purgeFailure = CKError(.networkFailure)

        let deleted = await coordinator.deleteHousehold(fridges.target)

        XCTAssertFalse(deleted)
        XCTAssertNotNil(coordinator.householdFailure)
        XCTAssertFalse(coordinator.households.contains { $0.id == fridges.target })
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.target)
        XCTAssertTrue(stillThere, "nothing was destroyed by the failed attempt")
    }

    // MARK: - Local effects

    func testDeletionRetiresTheFridgesReminders() async throws {
        let fridges = try await startWithTwoFridges()
        let item = InventoryItemSnapshot(
            id: UUID(), memberIDs: [UUID()], name: "Milk", normalizedName: "milk", quantity: 1,
            artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: InventoryDay.today(),
            expiryDay: InventoryDay.today().adding(days: 6)!, expirySource: .llmEstimate)
        await coordinator.reminders.reconcile(items: [item], accountScope: Self.scope(),
                                              householdID: fridges.target)
        XCTAssertFalse(notifications.pending.isEmpty)

        _ = await coordinator.deleteHousehold(fridges.target)

        await waitUntil("no reminder still names the deleted fridge") {
            self.notifications.pending.allSatisfy {
                !$0.identifier.contains(fridges.target.uuidString)
            }
        }
    }
}
