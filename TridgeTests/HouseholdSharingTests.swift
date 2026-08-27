import CloudKit
import CoreData
import XCTest
@testable import Tridge

/// The owner's side of sharing: who may create or refresh a share, what a
/// failed title write leaves behind, and what a refused attempt does *not*
/// change.
@MainActor
final class HouseholdSharingTests: XCTestCase {
    private var baseDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var loader: StackLoader!
    private var identity: FakeAccountIdentity!
    private var monitor: StoreScopedSyncMonitor!
    private var sharing: FakeHouseholdSharing!
    private var router: ShareInvitationRouter!
    private var coordinator: AccountSessionCoordinator!

    private static func scope(_ character: Character = "a") -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: character, count: 64))!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "HouseholdSharingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        sharing = FakeHouseholdSharing()
        router = ShareInvitationRouter()
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
            reminders: ReminderReconciler(center: FakeNotificationCenter(), defaults: defaults),
            defaults: defaults,
            barrier: BootstrapBarrierStore(defaults: defaults),
            activeHouseholds: ActiveHouseholdStore(defaults: defaults),
            upgrade: LegacyInventoryUpgrade(archive: FakeLegacyArchive(rows: [], exists: false),
                                            markers: UpgradeMarkers(defaults: defaults),
                                            effects: RecordingLegacyEffects()),
            invitations: router,
            makePersistence: loader.closure,
            makeSharing: { _ in sharing })
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

    @discardableResult
    private func startWithOwnedHousehold(name: String = "Home") async throws -> UUID {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let id = try insertHousehold(into: controller, name: name, ownership: .owned)
        controller.tearDown()
        await coordinator.start()
        await waitUntil("the household is selected") { self.coordinator.activeHouseholdID == id }
        return id
    }

    // MARK: - Owner only

    func testOnlyTheOwnerCanPrepareAShare() async throws {
        let owned = try await startWithOwnedHousehold()
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let received = try insertHousehold(into: controller, name: "Their Fridge",
                                           ownership: .received, author: "remote.peer")
        coordinator.refreshOnForeground()
        await waitUntil("the received household appears") { self.coordinator.households.count == 2 }

        let prepared = await coordinator.prepareShare(for: received)

        XCTAssertFalse(prepared)
        XCTAssertEqual(coordinator.householdFailure?.reason, .notOwner)
        XCTAssertNil(coordinator.preparedShare)
        XCTAssertEqual(sharing.prepareCount, 0)
        XCTAssertEqual(coordinator.activeHouseholdID, owned, "selection is untouched")
    }

    // MARK: - Preparing an invitation

    func testPreparingAShareSavesTheCurrentFridgeName() async throws {
        let owned = try await startWithOwnedHousehold(name: "Beach House")

        let prepared = await coordinator.prepareShare(for: owned)

        XCTAssertTrue(prepared)
        XCTAssertEqual(sharing.titles[owned], "Beach House")
        XCTAssertEqual(coordinator.preparedShare?.title, "Beach House")
        XCTAssertNil(coordinator.householdFailure)
    }

    func testAFailedTitleWritePresentsNothingAndLeavesARetryMarker() async throws {
        let owned = try await startWithOwnedHousehold()
        sharing.prepareFailure = CKError(.networkFailure)

        let prepared = await coordinator.prepareShare(for: owned)

        XCTAssertFalse(prepared)
        XCTAssertNil(coordinator.preparedShare, "ShareLink is never offered after this")
        XCTAssertTrue(coordinator.householdsWithStaleShareTitle.contains(owned))
        XCTAssertTrue(ShareTitleRetryStore(accountScope: Self.scope(), defaults: defaults)
            .needsRetry(owned), "the marker survives termination")
    }

    func testSendInviteRetriesADirtyTitleAndClearsTheMarker() async throws {
        let owned = try await startWithOwnedHousehold(name: "Home")
        sharing.prepareFailure = CKError(.networkFailure)
        _ = await coordinator.prepareShare(for: owned)
        XCTAssertTrue(coordinator.householdsWithStaleShareTitle.contains(owned))

        let prepared = await coordinator.prepareShare(for: owned)

        XCTAssertTrue(prepared)
        XCTAssertFalse(coordinator.householdsWithStaleShareTitle.contains(owned))
        XCTAssertFalse(ShareTitleRetryStore(accountScope: Self.scope(), defaults: defaults)
            .needsRetry(owned))
    }

    func testAPlatformLimitLeavesInventoryAndSelectionUnchanged() async throws {
        let owned = try await startWithOwnedHousehold()
        let itemsBefore = coordinator.inventory?.items ?? []
        sharing.prepareFailure = CKError(.tooManyParticipants)

        let prepared = await coordinator.prepareShare(for: owned)

        XCTAssertFalse(prepared)
        XCTAssertEqual(coordinator.householdFailure?.reason, .limitReached)
        XCTAssertEqual(coordinator.activeHouseholdID, owned)
        XCTAssertEqual(coordinator.inventory?.items, itemsBefore)
        XCTAssertEqual(coordinator.households.count, 1, "no imitation Household is created")
    }

    func testClearingThePreparedShareForcesTheNextInviteToRefresh() async throws {
        let owned = try await startWithOwnedHousehold()
        _ = await coordinator.prepareShare(for: owned)
        XCTAssertNotNil(coordinator.preparedShare)

        coordinator.clearPreparedShare()
        XCTAssertNil(coordinator.preparedShare)

        _ = await coordinator.prepareShare(for: owned)
        XCTAssertEqual(sharing.prepareCount, 2, "every invitation refreshes the share first")
    }

    // MARK: - Rename

    func testRenamingAnOwnedHouseholdCarriesTheShareTitleWithIt() async throws {
        let owned = try await startWithOwnedHousehold(name: "Home")
        _ = await coordinator.prepareShare(for: owned)
        coordinator.clearPreparedShare()

        let renamed = await coordinator.renameHousehold(owned, to: "Beach House")

        XCTAssertTrue(renamed)
        XCTAssertEqual(coordinator.activeHousehold?.name, "Beach House")
        XCTAssertEqual(sharing.titles[owned], "Beach House")
    }

    func testARenameWhoseTitleWriteFailsStillSavesTheFridgeName() async throws {
        let owned = try await startWithOwnedHousehold(name: "Home")
        _ = await coordinator.prepareShare(for: owned)
        coordinator.clearPreparedShare()
        sharing.prepareFailure = CKError(.networkFailure)

        let renamed = await coordinator.renameHousehold(owned, to: "Beach House")

        XCTAssertTrue(renamed, "the Household itself is saved first and independently")
        XCTAssertEqual(coordinator.activeHousehold?.name, "Beach House")
        XCTAssertTrue(coordinator.householdsWithStaleShareTitle.contains(owned))
    }

    func testAnUnsharedRenameNeverTouchesTheSharingService() async throws {
        let owned = try await startWithOwnedHousehold(name: "Home")

        _ = await coordinator.renameHousehold(owned, to: "Beach House")

        XCTAssertEqual(sharing.prepareCount, 0)
    }

    // MARK: - Acceptance

    func testAnAcceptedInvitationDoesNotChangeTheActiveHousehold() async throws {
        let owned = try await startWithOwnedHousehold()

        router.receive(FakePendingInvitation())
        await waitUntil("the invitation is accepted") { self.router.status == .accepted }

        XCTAssertEqual(sharing.acceptCount, 1)
        XCTAssertEqual(coordinator.activeHouseholdID, owned,
                       "the member selects the received fridge explicitly")
    }
}

/// A pending invitation for this app's container.
private struct FakePendingInvitation: ShareInvitationMetadata {
    let invitationContainerIdentifier = TridgeCloudKit.containerIdentifier
    let invitationParticipantStatus: CKShare.ParticipantStatus = .pending
}
