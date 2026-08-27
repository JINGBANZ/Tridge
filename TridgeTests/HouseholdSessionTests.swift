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
                             capabilities: FakeStoreCapabilities = FakeStoreCapabilities(),
                             repository: (any InventoryRepository)? = nil)
    -> HouseholdSession {
        // Captured into a local: the closure is `@Sendable`, and this suite's
        // statics are main-actor isolated.
        let day = Self.today
        let backing: any InventoryRepository = repository
            ?? CoreDataInventoryRepository(persistence: controller, capabilities: capabilities)
        return HouseholdSession(
            householdID: householdID ?? self.householdID,
            accountContext: accountContext,
            repository: backing,
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

    private func item(_ name: String, id: UUID) -> InventoryItemSnapshot {
        InventoryItemSnapshot(id: id, memberIDs: [id], name: name,
                              normalizedName: NameKey.normalize(name), quantity: 1,
                              artKey: ItemID.milk.rawValue, storage: .fridge,
                              purchaseDay: Self.today, expiryDay: Self.today.adding(days: 5)!,
                              expirySource: .llmEstimate)
    }

    private func projection(_ items: [InventoryItemSnapshot]) -> HouseholdProjection {
        HouseholdProjection(householdID: householdID, items: items, physicalItems: [],
                            inferredClaims: [], issues: [], stockIssues: [])
    }

    private func storedClaimCount(in householdID: UUID? = nil) throws -> Int {
        let context = controller.newWriterContext()
        var result: Result<Int, Error>!
        context.performAndWait {
            result = Result {
                let request = ItemMergeRecord.fetchRequest()
                if let householdID {
                    request.predicate = NSPredicate(format: "household.id == %@",
                                                    householdID as NSUUID)
                }
                return try context.count(for: request)
            }
        }
        return try result.get()
    }

    /// Two same-name roots written straight through the repository: the
    /// Household then has an exact-name link to infer but no durable claim,
    /// so only a reconciliation pass over *that* Household can insert one.
    private func seedSameNamePair(in householdID: UUID) async throws {
        let repository = CoreDataInventoryRepository(persistence: controller,
                                                     capabilities: FakeStoreCapabilities())
        for _ in 0..<2 {
            _ = try await repository.addManualItem(
                AddManualItemCommand(householdID: householdID, commandID: UUID(),
                                     draft: draft("Whole Milk")),
                today: Self.today)
        }
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

    /// `@MainActor` does not order these on its own: `refresh()` and a command
    /// both suspend across their repository awaits and can resume in either
    /// order. A read that started first must not land on top of a purchase that
    /// finished after it.
    func testASlowerReadNeverReplacesANewerPurchase() async throws {
        let purchased = projection([item("Whole Milk", id: Self.id(1))])
        let repository = GatedInventoryRepository(read: .empty(householdID: householdID),
                                                  commands: [purchased])
        let gate = TestGate()
        repository.readGate = { await gate.wait() }
        let session = makeSession(repository: repository)

        let slowRead = Task { await session.refresh() }
        await waitUntil("the read to start") { repository.readCount == 1 }
        let saved = await session.addManualItem(draft("Whole Milk", id: Self.id(1)))
        await gate.open()
        await slowRead.value

        XCTAssertTrue(saved)
        XCTAssertEqual(session.items.map(\.name), ["Whole Milk"],
                       "the older read must not replace the purchase that landed after it")

        // The newer-wins rule discards stale results, never later ones.
        await session.refresh()
        XCTAssertTrue(session.items.isEmpty, "a read started afterwards still applies")
    }

    /// The claims a command owes belong to the fridge it wrote to. `select`
    /// mutates `householdID` in its synchronous prefix, so it can re-point the
    /// session entirely inside a command's suspension — and its own `load()`
    /// only ever reconciles the *new* fridge, so a reconciliation that read
    /// `householdID` after the write would drop the older one's claim.
    func testACommandPersistsClaimsForTheHouseholdItWroteTo() async throws {
        try await seedSameNamePair(in: householdID)
        try await seedSameNamePair(in: otherHouseholdID)
        let repository = GatedInventoryRepository(read: .empty(householdID: householdID),
                                                  commands: [.empty(householdID: householdID)])
        let gate = TestGate()
        repository.commandGate = { await gate.wait() }
        let session = makeSession(repository: repository)
        let pending = draft("Whole Milk")
        let nextHousehold = otherHouseholdID!

        let purchase = Task { await session.addManualItem(pending) }
        await waitUntil("the command to start") { repository.commandCount == 1 }
        let switched = Task { await session.select(householdID: nextHousehold) }
        await waitUntil("the switch to re-point the session") {
            session.householdID == nextHousehold
        }
        await gate.open()
        _ = await purchase.value
        await switched.value

        XCTAssertEqual(try storedClaimCount(in: householdID), 1,
                       "the fridge the purchase was written to still gets its durable claim")
        XCTAssertEqual(try storedClaimCount(in: otherHouseholdID), 1,
                       "the fridge switched to reconciles through its own load")
    }

    /// Two purchases in flight at once. The repository serializes the saves, but
    /// nothing ties that order to the order they were issued in — each command
    /// reaches `AccountTaskRegistry` as its own unstructured task — and nothing
    /// orders the two main-actor continuations that resume afterwards either. A
    /// ticket can only rank the applications, so the older transaction's
    /// projection, which predates the newer purchase, could be the one left on
    /// screen. Each purchase therefore waits for the one before it to apply.
    func testASecondPurchaseWaitsForTheFirstToApply() async throws {
        let milk = item("Whole Milk", id: Self.id(1))
        let eggs = item("Eggs", id: Self.id(2))
        let repository = GatedInventoryRepository(
            read: .empty(householdID: householdID),
            commands: [projection([milk]), projection([milk, eggs])])
        let gate = TestGate()
        repository.commandGate = { await gate.wait() }
        let session = makeSession(repository: repository)

        let first = Task { await session.addManualItem(draft("Whole Milk", id: Self.id(1))) }
        await waitUntil("the first purchase to reach the repository") {
            repository.commandCount == 1
        }
        let second = Task {
            await session.addManualItem(draft("Eggs", id: Self.id(2), art: .eggs))
        }
        // Bounded, because the assertion is that this never happens: nothing
        // else can signal a purchase that must still be waiting its turn.
        await neverHappens("the second purchase reached the repository while the first was writing") {
            repository.commandCount > 1
        }

        await gate.open()
        let savedFirst = await first.value
        let savedSecond = await second.value

        XCTAssertTrue(savedFirst)
        XCTAssertTrue(savedSecond)
        XCTAssertEqual(repository.commandCount, 2, "the held purchase still ran")
        XCTAssertEqual(session.items.map(\.name), ["Whole Milk", "Eggs"],
                       "the projection taken last is the one left on screen")
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
