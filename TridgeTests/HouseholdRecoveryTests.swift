import CloudKit
import CoreData
import XCTest
@testable import Tridge

/// Recovering from a zone that is gone or a key that was rotated.
///
/// The failures look similar in the logs and mean very different things to the
/// user, so the interesting assertions are about who is asked, what is said, and
/// what is never destroyed without permission.
@MainActor
final class HouseholdRecoveryTests: XCTestCase {
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
            .appendingPathComponent("HouseholdRecoveryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "HouseholdRecoveryTests-\(UUID().uuidString)"
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
                                 ownership: HouseholdOwnership) throws -> UUID {
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

    private func startWithBothFridges() async throws -> (owned: UUID, received: UUID) {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        let owned = try insertHousehold(into: controller, name: "Home", ownership: .owned)
        let received = try insertHousehold(into: controller, name: "Theirs", ownership: .received)
        controller.tearDown()
        await coordinator.start()
        await waitUntil("both fridges are listed") { self.coordinator.households.count == 2 }
        return (owned, received)
    }

    private func addItem(_ name: String, quantity: Int64 = 2) async throws {
        let session = try XCTUnwrap(coordinator.inventory)
        let saved = await session.addManualItem(
            PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: name, quantity: quantity,
                          artKey: ItemID.milk.rawValue, storage: .fridge,
                          purchaseDay: Self.today, expiryDay: Self.today.adding(days: 6)!,
                          expirySource: .llmEstimate, explicitMetadataFields: []))
        XCTAssertTrue(saved)
    }

    /// Emits the failed event the container reports for each cause.
    private func emitRecovery(_ need: SyncRecoveryNeed, ownedStore: Bool) {
        guard let context = coordinator.session?.context else { return }
        let store = ownedStore ? context.privateStoreIdentifier : context.sharedStoreIdentifier
        let id = UUID().uuidString
        monitor.receive(SyncEvent(identifier: id, storeIdentifier: store, kind: .importChanges,
                                  isComplete: false))
        monitor.receive(SyncEvent(identifier: id, storeIdentifier: store, kind: .importChanges,
                                  isComplete: true, succeeded: false, recovery: need))
    }

    // MARK: - Telling the two causes apart

    func testTheTwoCausesNeverReadAsEachOther() {
        let deleted = HouseholdRecoveryRequest(cause: .zoneDeleted, role: .owner,
                                               householdIDs: [UUID()])
        let reset = HouseholdRecoveryRequest(cause: .encryptionKeyReset, role: .owner,
                                             householdIDs: [UUID()])

        XCTAssertNotEqual(deleted.title, reset.title)
        XCTAssertNotEqual(deleted.message, reset.message)
        XCTAssertTrue(reset.message.lowercased().contains("key"))
        XCTAssertFalse(deleted.message.lowercased().contains("key"))
    }

    func testRecoveryWordingExposesNoOpaqueTarget() {
        for cause in [HouseholdRecoveryRequest.Cause.zoneDeleted, .encryptionKeyReset] {
            for role in [HouseholdRecoveryRequest.Role.owner, .member] {
                let request = HouseholdRecoveryRequest(cause: cause, role: role,
                                                       householdIDs: [UUID()])
                let text = (request.title + request.message).lowercased()
                for opaque in ["zone", "record", "ckshare", "http", "recordname"] {
                    XCTAssertFalse(text.contains(opaque),
                                   "\(cause)/\(role) must not expose \(opaque)")
                }
            }
        }
    }

    func testOnlyAnOwnerIsAskedBeforeAnythingLocalIsTouched() {
        XCTAssertTrue(HouseholdRecoveryRequest(cause: .zoneDeleted, role: .owner,
                                               householdIDs: []).needsConfirmation)
        XCTAssertFalse(HouseholdRecoveryRequest(cause: .zoneDeleted, role: .member,
                                                householdIDs: []).needsConfirmation,
                       "a member cannot recreate somebody else's zone")
    }

    // MARK: - Owner

    func testAnOwnersZoneLossHidesTheFridgeAndWaitsForConfirmation() async throws {
        let fridges = try await startWithBothFridges()
        try await addItem("Milk")
        await waitUntil("the fridge has reminders") {
            self.notifications.pending.contains { $0.identifier.contains(fridges.owned.uuidString) }
        }

        emitRecovery(.zoneDeleted, ownedStore: true)

        await waitUntil("recovery is pending") { self.coordinator.pendingRecovery != nil }
        XCTAssertEqual(coordinator.pendingRecovery?.role, .owner)
        XCTAssertFalse(coordinator.households.contains { $0.id == fridges.owned },
                       "hidden from normal interaction at once")
        await waitUntil("its reminders are retired") {
            self.notifications.pending.allSatisfy {
                !$0.identifier.contains(fridges.owned.uuidString)
            }
        }
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.owned)
        XCTAssertTrue(stillThere, "nothing local is purged before the owner agrees")
        XCTAssertEqual(sharing.purgedHouseholds, [])
    }

    func testDeferringLeavesTheFridgeHiddenAndNothingDestroyed() async throws {
        let fridges = try await startWithBothFridges()
        try await addItem("Milk")
        emitRecovery(.encryptionKeyReset, ownedStore: true)
        await waitUntil("recovery is pending") { self.coordinator.pendingRecovery != nil }

        coordinator.dismissRecovery()

        XCTAssertNil(coordinator.pendingRecovery)
        XCTAssertFalse(coordinator.households.contains { $0.id == fridges.owned })
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let stillThere = try await controller.containsHousehold(fridges.owned)
        XCTAssertTrue(stillThere)
    }

    func testConfirmingKeepsTheLocalCacheInAFreshFridgeAndDropsTheOldZone() async throws {
        let fridges = try await startWithBothFridges()
        try await addItem("Milk", quantity: 3)
        emitRecovery(.encryptionKeyReset, ownedStore: true)
        await waitUntil("recovery is pending") { self.coordinator.pendingRecovery != nil }

        let recovered = await coordinator.confirmRecovery()

        XCTAssertTrue(recovered)
        XCTAssertNil(coordinator.pendingRecovery)
        XCTAssertEqual(sharing.purgedHouseholds, [fridges.owned])
        let controller = try XCTUnwrap(coordinator.session?.persistence)
        let oldStillThere = try await controller.containsHousehold(fridges.owned)
        XCTAssertFalse(oldStillThere)

        let replacement = try XCTUnwrap(coordinator.households.first { $0.ownership == .owned })
        XCTAssertNotEqual(replacement.id, fridges.owned)
        XCTAssertEqual(replacement.name, "Home", "the fridge keeps its name")
        await waitUntil("the kept inventory is on screen") {
            self.coordinator.inventory?.items.first?.name == "Milk"
                && self.coordinator.inventory?.items.first?.quantity == 3
        }
    }

    /// The owner's own permission failing is not a reason to delete their only
    /// copy — that is a recovery decision, not a cleanup.
    func testAnOwnersRefusedWriteNeverPurgesTheirFridge() async throws {
        let fridges = try await startWithBothFridges()

        coordinator.handleLostAccess(to: fridges.owned)

        await neverHappens("the owned fridge is removed") {
            !self.coordinator.households.contains { $0.id == fridges.owned }
        }
        XCTAssertEqual(sharing.purgedHouseholds, [])
    }

    // MARK: - Member

    func testAMemberLosesAccessWithoutBeingAskedAndIsToldToAskForAnInvitation() async throws {
        let fridges = try await startWithBothFridges()

        emitRecovery(.encryptionKeyReset, ownedStore: false)

        let controller = try XCTUnwrap(coordinator.session?.persistence)
        await waitUntil("the received fridge is really gone") {
            // Split rather than `&&`: the right-hand side of a short-circuit
            // operator is an autoclosure, which cannot await.
            guard !self.coordinator.households.contains(where: { $0.id == fridges.received })
            else { return false }
            // An unreadable store is not proof of absence, so it keeps waiting.
            guard let stillStored = try? await controller.containsHousehold(fridges.received)
            else { return false }
            return !stillStored
        }
        let request = try XCTUnwrap(coordinator.pendingRecovery)
        XCTAssertEqual(request.role, .member)
        XCTAssertFalse(request.needsConfirmation)
        XCTAssertTrue(request.message.lowercased().contains("invitation"))
        XCTAssertEqual(coordinator.activeHouseholdID, fridges.owned, "selection falls back")
    }

    // MARK: - Store and generation isolation

    func testARecoveryForAStoreThisSessionNeverOpenedIsIgnored() {
        let monitor = StoreScopedSyncMonitor()
        var reported: [SyncRecoveryNeed] = []
        monitor.onRecoveryNeeded = { need, _ in reported.append(need) }
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation, storeIdentifiers: ["mine.private"])

        monitor.receive(SyncEvent(identifier: "1", storeIdentifier: "someone-else.private",
                                  kind: .importChanges, isComplete: false))
        monitor.receive(SyncEvent(identifier: "1", storeIdentifier: "someone-else.private",
                                  kind: .importChanges, isComplete: true, succeeded: false,
                                  recovery: .zoneDeleted))

        XCTAssertTrue(reported.isEmpty)
    }

    func testARecoveryIsReportedOncePerStorePerSession() {
        let monitor = StoreScopedSyncMonitor()
        var reported: [SyncRecoveryNeed] = []
        monitor.onRecoveryNeeded = { need, _ in reported.append(need) }
        let generation = AccountGeneration()
        monitor.prepareSession(generation: generation)
        monitor.activateSession(generation: generation, storeIdentifiers: ["mine.private"])

        for attempt in 0..<3 {
            let id = "attempt-\(attempt)"
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: "mine.private",
                                      kind: .importChanges, isComplete: false))
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: "mine.private",
                                      kind: .importChanges, isComplete: true, succeeded: false,
                                      recovery: .zoneDeleted))
        }

        XCTAssertEqual(reported, [.zoneDeleted], "the container retries; the user is asked once")
    }

    func testTheEncryptionKeyFlagWinsOverTheZoneNotFoundCodeItArrivesWith() {
        let plainZoneLoss = CKError(.zoneNotFound)
        let keyReset = CKError(.zoneNotFound,
                               userInfo: [CKErrorUserDidResetEncryptedDataKey: true])

        XCTAssertEqual(SyncEvent.recoveryNeed(plainZoneLoss), .zoneDeleted)
        XCTAssertEqual(SyncEvent.recoveryNeed(keyReset), .encryptionKeyReset)
        XCTAssertNil(SyncEvent.recoveryNeed(CKError(.networkUnavailable)))
        XCTAssertNil(SyncEvent.recoveryNeed(nil))
    }
}
