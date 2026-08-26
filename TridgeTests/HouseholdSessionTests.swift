import CoreData
import XCTest
@testable import Tridge

/// The value snapshots Home reads, and what happens to the user's draft when a
/// command cannot be applied.
@MainActor
final class HouseholdSessionTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var tasks: AccountTaskRegistry!
    private var accountContext: AccountSessionContext!
    private var householdID: UUID!
    private var otherHouseholdID: UUID!

    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!
    private static let occurredAt = Date(timeIntervalSince1970: 1_787_097_600)
    private static let scope = AccountScopeHash(digest: String(repeating: "b", count: 64))!

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdSessionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope, baseDirectory: baseDirectory))

        let generationContext = AccountGenerationContext(accountScope: Self.scope)
        accountContext = AccountSessionContext(
            generationContext: generationContext,
            privateStoreIdentifier: controller.privateStore.identifier,
            sharedStoreIdentifier: controller.sharedStore.identifier)
        tasks = AccountTaskRegistry()
        await tasks.open(generationContext.generation)

        householdID = try makeHousehold(named: "Home")
        otherHouseholdID = try makeHousehold(named: "Cabin")
    }

    override func tearDown() async throws {
        await tasks?.closeAndDrain()
        tasks = nil
        controller?.tearDown()
        controller = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private func makeHousehold(named name: String) throws -> UUID {
        let context = controller.newWriterContext()
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
                try StoreRouting.assign([household], to: controller.privateStore, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    private func makeSession(householdID: UUID? = nil,
                             capabilities: FakeStoreCapabilities = FakeStoreCapabilities())
    -> HouseholdSession {
        // Captured into a local: the closure is `@Sendable`, and this suite's
        // statics are main-actor isolated.
        let day = Self.today
        return HouseholdSession(
            householdID: householdID ?? self.householdID,
            accountContext: accountContext,
            repository: CoreDataInventoryRepository(persistence: controller,
                                                    capabilities: capabilities),
            reconciler: DuplicateReconciler(persistence: controller, capabilities: capabilities),
            tasks: tasks,
            today: { day })
    }

    private func draft(_ name: String, id: UUID = UUID(), quantity: Int64 = 1,
                       art: ItemID = .milk) -> PurchaseDraft {
        PurchaseDraft(itemID: id, stockChangeID: UUID(), name: name, quantity: quantity,
                      artKey: art.rawValue, storage: .fridge, purchaseDay: Self.today,
                      expiryDay: Self.today.adding(days: 5)!, expirySource: .llmEstimate,
                      explicitMetadataFields: [], occurredAt: Self.occurredAt)
    }

    private func storedClaimCount() throws -> Int {
        let context = controller.newWriterContext()
        var result: Result<Int, Error>!
        context.performAndWait {
            result = Result { try context.count(for: ItemMergeRecord.fetchRequest()) }
        }
        return try result.get()
    }

    // MARK: - Rendering

    func testAPurchaseImmediatelyProjectsIntoTheSnapshotsHomeRenders() async throws {
        let session = makeSession()

        let saved = await session.addManualItem(draft("Whole Milk", id: Self.id(1), quantity: 2))

        XCTAssertTrue(saved)
        XCTAssertNil(session.lastFailure)
        XCTAssertEqual(session.items.map(\.name), ["Whole Milk"])
        XCTAssertEqual(session.items.first?.quantity, 2)
        XCTAssertEqual(session.purchaseHistory.map(\.id), [Self.id(1)])
    }

    /// The row appears merged before the durable claim exists, and the claim is
    /// persisted straight afterwards — the UI never flashes two rows.
    func testASameNamePurchaseProjectsAsOneRowAndPersistsTheClaim() async throws {
        let session = makeSession()
        await session.addManualItem(draft("Whole Milk", id: Self.id(1), quantity: 2))

        await session.addManualItem(draft("Whole Milk", id: Self.id(2), quantity: 3))

        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.items.first?.quantity, 5)
        XCTAssertEqual(session.purchaseHistory.count, 2, "neither history was discarded")
        XCTAssertEqual(try storedClaimCount(), 1)
    }

    func testAReceiptSavesEveryRowAndRendersThemTogether() async throws {
        let session = makeSession()

        let saved = await session.addReviewedRows([
            draft("Whole Milk", id: Self.id(1), quantity: 2),
            draft("Eggs", id: Self.id(2), quantity: 12, art: .eggs),
        ])

        XCTAssertTrue(saved)
        XCTAssertEqual(Set(session.items.map(\.name)), ["Whole Milk", "Eggs"])
    }

    func testSwitchingHouseholdsShowsOnlyTheNewFridge() async throws {
        let session = makeSession()
        await session.addManualItem(draft("Whole Milk", id: Self.id(1)))

        await session.select(householdID: otherHouseholdID)

        XCTAssertEqual(session.householdID, otherHouseholdID)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(session.purchaseHistory.isEmpty)
    }

    // MARK: - Refusals

    func testCapabilityDenialWritesNothingAndLeavesTheDraftUsable() async throws {
        let session = makeSession(capabilities: FakeStoreCapabilities(canModify: false))
        let pending = draft("Whole Milk", id: Self.id(1))

        let saved = await session.addManualItem(pending)

        XCTAssertFalse(saved, "the caller keeps its draft")
        XCTAssertEqual(session.lastFailure?.reason, .permissionDenied)
        XCTAssertEqual(session.lastFailure?.message,
                       "You no longer have permission to change this household.")
        XCTAssertTrue(session.items.isEmpty)

        await session.refresh()
        XCTAssertTrue(session.items.isEmpty, "nothing was written")
    }

    func testAStaleHouseholdSelectionFailsWithoutTouchingInventory() async throws {
        let session = makeSession(householdID: UUID())

        let saved = await session.addManualItem(draft("Whole Milk"))

        XCTAssertFalse(saved)
        XCTAssertEqual(session.lastFailure?.reason, .householdUnavailable)
    }

    func testAnInvalidatedSessionAppliesNothingElse() async throws {
        let session = makeSession()
        await session.addManualItem(draft("Whole Milk", id: Self.id(1)))

        session.invalidate()
        let saved = await session.addManualItem(draft("Eggs", id: Self.id(2), art: .eggs))
        await session.refresh()

        XCTAssertFalse(saved)
        XCTAssertTrue(session.items.isEmpty, "a released account's rows never come back")
        XCTAssertNil(session.lastFailure)
    }
}
