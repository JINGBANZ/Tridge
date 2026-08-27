import CoreData
import XCTest
@testable import Tridge

/// The Household screen's two jobs: saying truthfully what each fridge is, and
/// switching which one is active without that choice leaving this device.
@MainActor
final class HouseholdScreenTests: XCTestCase {
    private var baseDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var loader: StackLoader!
    private var identity: FakeAccountIdentity!
    private var monitor: StoreScopedSyncMonitor!
    private var coordinator: AccountSessionCoordinator!

    private static func scope(_ character: Character = "a") -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: character, count: 64))!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdScreenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "HouseholdScreenTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        coordinator = AccountSessionCoordinator(
            identity: identity, syncMonitor: monitor,
            reminders: ReminderReconciler(center: FakeNotificationCenter(), defaults: defaults),
            defaults: defaults,
            barrier: BootstrapBarrierStore(defaults: defaults),
            activeHouseholds: ActiveHouseholdStore(defaults: defaults),
            upgrade: LegacyInventoryUpgrade(archive: FakeLegacyArchive(rows: [], exists: false),
                                            markers: UpgradeMarkers(defaults: defaults),
                                            effects: RecordingLegacyEffects()),
            makePersistence: loader.closure)
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
                                 ownership: HouseholdOwnership,
                                 createdAt: Date = Date(),
                                 author: String? = nil) throws -> UUID {
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
                household.createdAt = createdAt
                household.modifiedAt = createdAt
                try StoreRouting.assign([household], to: store, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    /// A validated cache with one owned Household, which is what the screen
    /// opens onto in the ordinary case.
    private func startWithOwnedHousehold(name: String = "Home") async throws -> UUID {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let id = try insertHousehold(into: controller, name: name, ownership: .owned)
        controller.tearDown()
        await coordinator.start()
        await waitUntil("the household is selected") { self.coordinator.activeHouseholdID == id }
        return id
    }

    // MARK: - Ownership

    func testOwnershipComesFromTheStoreTheHouseholdLivesIn() async throws {
        let owned = try await startWithOwnedHousehold()
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let received = try insertHousehold(into: controller, name: "Their Fridge",
                                           ownership: .received, author: "remote.peer")

        coordinator.refreshOnForeground()
        await waitUntil("the received household appears") { self.coordinator.households.count == 2 }

        let snapshots = Dictionary(coordinator.households.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(HouseholdRowText.ownership(for: try XCTUnwrap(snapshots[owned])),
                       "Owned by you")
        XCTAssertEqual(HouseholdRowText.ownership(for: try XCTUnwrap(snapshots[received])),
                       "Shared with you")
    }

    /// An accepted invitation adds the Household to the list; the member picks
    /// it explicitly (ADR 0013).
    func testAnImportedHouseholdDoesNotChangeTheActiveOne() async throws {
        let owned = try await startWithOwnedHousehold()
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        _ = try insertHousehold(into: controller, name: "Their Fridge", ownership: .received,
                                author: "remote.peer")

        coordinator.refreshOnForeground()
        await waitUntil("the received household appears") { self.coordinator.households.count == 2 }

        XCTAssertEqual(coordinator.activeHouseholdID, owned)
    }

    // MARK: - Selection

    func testSelectingARowPersistsOnlyTheAccountScopedUUID() async throws {
        let owned = try await startWithOwnedHousehold()
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let received = try insertHousehold(into: controller, name: "Their Fridge",
                                           ownership: .received, author: "remote.peer")
        coordinator.refreshOnForeground()
        await waitUntil("the received household appears") { self.coordinator.households.count == 2 }

        coordinator.selectHousehold(received)

        XCTAssertEqual(coordinator.activeHouseholdID, received)
        await waitUntil("inventory follows the selection") {
            self.coordinator.inventory?.householdID == received
        }
        XCTAssertEqual(ActiveHouseholdStore(defaults: defaults).savedID(for: Self.scope()),
                       received)
        XCTAssertNil(ActiveHouseholdStore(defaults: defaults).savedID(for: Self.scope("b")),
                     "another account never reads this one's selection")
        XCTAssertNotEqual(owned, received)
    }

    func testSelectingAHouseholdThatIsNoLongerThereFallsBack() async throws {
        let owned = try await startWithOwnedHousehold()

        coordinator.selectHousehold(UUID())

        XCTAssertEqual(coordinator.activeHouseholdID, owned,
                       "an unknown id runs the deterministic fallback instead")
    }

    func testSelectingTheActiveHouseholdIsANoOp() async throws {
        let owned = try await startWithOwnedHousehold()
        let session = try XCTUnwrap(coordinator.inventory)

        coordinator.selectHousehold(owned)

        XCTAssertIdentical(coordinator.inventory, session, "the session is not rebuilt")
    }

    // MARK: - Transition gating

    func testOneHouseholdActionRunsAtATime() async throws {
        _ = try await startWithOwnedHousehold()
        let gate = TestGate()

        async let first = coordinator.runHouseholdAction {
            await gate.wait()
            return true
        }
        await waitUntil("the first action starts") { self.coordinator.isHouseholdActionInFlight }

        let second = await coordinator.runHouseholdAction { true }
        XCTAssertFalse(second, "a second tap is dropped, never queued")

        await gate.open()
        let firstResult = await first
        XCTAssertTrue(firstResult)
        XCTAssertFalse(coordinator.isHouseholdActionInFlight)
    }

    // MARK: - Sync state

    func testEverySyncStateSaysWhatItMeansInWords() {
        XCTAssertEqual(SyncStatusPresentation(.upToDate).label, "Up to date")
        XCTAssertEqual(SyncStatusPresentation(.syncing).label, "Syncing…")
        XCTAssertEqual(SyncStatusPresentation(.offline).label,
                       "Offline — changes will sync later")
        XCTAssertEqual(SyncStatusPresentation(.needsAttention).label, "iCloud needs attention")

        let symbols = [SyncStatus.upToDate, .syncing, .offline, .needsAttention]
            .map { SyncStatusPresentation($0).symbol }
        XCTAssertEqual(Set(symbols).count, symbols.count,
                       "each state is distinguishable without colour")
    }
}
