import CloudKit
import CoreData
import XCTest
@testable import Tridge

/// Leaving a received Household, and losing access to one without asking.
///
/// Both paths end the same way: the fridge is gone from this device, its
/// reminders are retired, selection has fallen back — and the owner's data is
/// untouched, because a member can only remove their own participation.
@MainActor
final class HouseholdLeaveTests: XCTestCase {
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

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdLeaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "HouseholdLeaveTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        notifications = FakeNotificationCenter()
        sharing = FakeHouseholdSharing()
        let sharing = self.sharing!
        coordinator = AccountSessionCoordinator(
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

    override func tearDown() async throws {
        await coordinator?.shutDown()
        coordinator = nil
        loader?.tearDownAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    // MARK: - Seeding

    @discardableResult
    private func insertHousehold(into controller: PersistenceController, name: String,
                                 ownership: HouseholdOwnership, author: String? = nil) throws
    -> UUID {
        let context: NSManagedObjectContext
        if let author {
            context = controller.container.newBackgroundContext()
            context.transactionAuthor = author
        } else {
            context = controller.newWriterContext()
        }
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

    /// An owned fridge plus a received one, with the received one active — the
    /// state a member is in when Leave is the interesting action.
    private func startWithBothFridges() async throws -> (owned: UUID, received: UUID) {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let owned = try insertHousehold(into: controller, name: "Home", ownership: .owned)
        let received = try insertHousehold(into: controller, name: "Their Fridge",
                                           ownership: .received)
        controller.tearDown()
        await coordinator.start()
        await waitUntil("both fridges are listed") { self.coordinator.households.count == 2 }
        coordinator.selectHousehold(received)
        await waitUntil("the received fridge is active") {
            self.coordinator.activeHouseholdID == received
        }
        return (owned, received)
    }

    private func privateHouseholdCount() async throws -> Int {
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let context = controller.newReaderContext()
        return await context.perform {
            let request = HouseholdRecord.fetchRequest()
            request.affectedStores = [controller.privateStore]
            return (try? context.count(for: request)) ?? -1
        }
    }

    // MARK: - Leaving

    func testLeavingRemovesTheFridgeLocallyAndFallsBack() async throws {
        let fridges = try await startWithBothFridges()

        let left = await coordinator.leaveHousehold(fridges.received)

        XCTAssertTrue(left)
        XCTAssertEqual(sharing.purgedHouseholds, [fridges.received])
        XCTAssertEqual(coordinator.households.map(\.id), [fridges.owned])
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.owned)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(fridges.received)
        XCTAssertFalse(stillThere, "local absence is verified, not assumed")
    }

    func testLeavingNeverMakesAPrivateCopy() async throws {
        let fridges = try await startWithBothFridges()
        let before = try await privateHouseholdCount()

        _ = await coordinator.leaveHousehold(fridges.received)

        let after = try await privateHouseholdCount()
        XCTAssertEqual(after, before, "leaving copies nothing into the member's own store")
    }

    func testLeavingRetiresOnlyThatFridgesReminders() async throws {
        let fridges = try await startWithBothFridges()
        let item = InventoryItemSnapshot(
            id: UUID(), memberIDs: [UUID()], name: "Milk", normalizedName: "milk", quantity: 1,
            artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: InventoryDay.today(),
            expiryDay: InventoryDay.today().adding(days: 6)!, expirySource: .llmEstimate)
        await coordinator.reminders.reconcile(items: [item], accountScope: Self.scope(),
                                              householdID: fridges.received)
        await coordinator.reminders.reconcile(items: [item], accountScope: Self.scope(),
                                              householdID: fridges.owned)
        XCTAssertEqual(notifications.pending.count, 4)

        _ = await coordinator.leaveHousehold(fridges.received)

        await waitUntil("only the remaining fridge's reminders are left") {
            self.notifications.pending.allSatisfy {
                $0.identifier.contains(fridges.owned.uuidString)
            }
        }
        XCTAssertEqual(notifications.pending.count, 2)
    }

    /// A server zone that is already gone is a cleanup path, not completion:
    /// whatever is still local has to be deleted and verified absent.
    func testAnAlreadyMissingZoneStillCleansUpLocally() async throws {
        let fridges = try await startWithBothFridges()
        sharing.missingZones = [fridges.received]

        let left = await coordinator.leaveHousehold(fridges.received)

        XCTAssertTrue(left)
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(fridges.received)
        XCTAssertFalse(stillThere)
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.owned)
    }

    func testAFailedPurgeKeepsTheFridgeHiddenAndRetryable() async throws {
        let fridges = try await startWithBothFridges()
        sharing.purgeFailure = CKError(.networkFailure)

        let left = await coordinator.leaveHousehold(fridges.received)

        XCTAssertFalse(left)
        XCTAssertNotNil(coordinator.householdFailure)
        XCTAssertFalse(coordinator.households.contains { $0.id == fridges.received },
                       "no stale inventory is exposed while the failure stands")
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(fridges.received)
        XCTAssertTrue(stillThere, "nothing was destroyed by the failed attempt")

        let retried = await coordinator.leaveHousehold(fridges.received)
        XCTAssertFalse(retried, "the hidden fridge is no longer offered as a Leave target")
    }

    func testLeavingAnOwnedHouseholdIsRefused() async throws {
        let fridges = try await startWithBothFridges()

        let left = await coordinator.leaveHousehold(fridges.owned)

        XCTAssertFalse(left)
        XCTAssertEqual(coordinator.householdFailure?.reason, .householdUnavailable)
        XCTAssertEqual(sharing.purgedHouseholds, [], "an owner's zone is never purged by Leave")
    }

    // MARK: - Lost access

    func testObservedLostAccessHidesTheFridgeImmediatelyAndFallsBack() async throws {
        let fridges = try await startWithBothFridges()

        coordinator.handleLostAccess(to: fridges.received)

        XCTAssertFalse(coordinator.households.contains { $0.id == fridges.received },
                       "hidden before any purge is attempted")
        await waitUntil("selection falls back") {
            self.coordinator.activeHouseholdID == fridges.owned
        }
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = await controller.containsHousehold(fridges.received)
        XCTAssertFalse(stillThere)
    }

    func testLostAccessForAFridgeThatIsAlreadyGoneDoesNothing() async throws {
        let fridges = try await startWithBothFridges()
        _ = await coordinator.leaveHousehold(fridges.received)
        let purgedBefore = sharing.purgedHouseholds

        coordinator.handleLostAccess(to: fridges.received)

        XCTAssertEqual(sharing.purgedHouseholds, purgedBefore)
    }
}
