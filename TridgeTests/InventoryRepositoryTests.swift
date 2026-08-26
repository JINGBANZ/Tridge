import CoreData
import Foundation
import XCTest
@testable import Tridge

/// Purchases through the repository, with CloudKit disabled: store routing,
/// atomic saves, retry behavior, the causal stamp every root carries, and the
/// lossless same-name convergence Home renders.
final class InventoryRepositoryTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var repository: CoreDataInventoryRepository!
    private var reconciler: DuplicateReconciler!
    private var householdID: UUID!

    /// A fixed civil day, so an expiry offset never depends on when the suite
    /// happens to run.
    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!
    /// Allocated with the command in production, so a retry can reproduce the
    /// identical row; fixed here for the same reason.
    private static let occurredAt = Date(timeIntervalSince1970: 1_787_097_600)

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("InventoryRepositoryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope, baseDirectory: baseDirectory))
        repository = CoreDataInventoryRepository(persistence: controller,
                                                 capabilities: FakeStoreCapabilities())
        reconciler = DuplicateReconciler(persistence: controller,
                                         capabilities: FakeStoreCapabilities())
        householdID = try makeHousehold(in: controller.privateStore)
    }

    override func tearDown() async throws {
        repository = nil
        reconciler = nil
        controller?.tearDown()
        controller = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private static let scope = AccountScopeHash(digest: String(repeating: "a", count: 64))!

    /// Byte-ordered ids, so which physical root is canonical is decided by the
    /// test rather than by chance.
    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    // MARK: - Seeding

    @discardableResult
    private func makeHousehold(in store: NSPersistentStore, name: String = "Home") throws -> UUID {
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
                try StoreRouting.assign([household], to: store, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    private func draft(_ name: String, id: UUID = UUID(), stockChangeID: UUID = UUID(),
                       quantity: Int64 = 1, art: ItemID = .milk,
                       storage: StorageLocation = .fridge, expiresInDays: Int = 5,
                       expirySource: ExpirySource = .llmEstimate,
                       explicit: Set<ExplicitMetadataField> = [],
                       occurredAt: Date = InventoryRepositoryTests.occurredAt) -> PurchaseDraft {
        PurchaseDraft(itemID: id, stockChangeID: stockChangeID, name: name, quantity: quantity,
                      artKey: art.rawValue, storage: storage, purchaseDay: Self.today,
                      expiryDay: Self.today.adding(days: expiresInDays)!,
                      expirySource: expirySource, explicitMetadataFields: explicit,
                      occurredAt: occurredAt)
    }

    @discardableResult
    private func addManual(_ draft: PurchaseDraft,
                           to household: UUID? = nil) async throws -> HouseholdProjection {
        try await repository.addManualItem(
            AddManualItemCommand(householdID: household ?? householdID, commandID: UUID(),
                                 draft: draft),
            today: Self.today)
    }

    @discardableResult
    private func addRows(_ rows: [PurchaseDraft],
                         to household: UUID? = nil) async throws -> HouseholdProjection {
        try await repository.addReviewedRows(
            AddReviewedRowsCommand(householdID: household ?? householdID, commandID: UUID(),
                                   rows: rows),
            today: Self.today)
    }

    // MARK: - Reading what was written

    /// The persisted shape of one purchase root, read back with no reducer in
    /// between, so a test asserts on what really went into the store.
    private struct StoredRoot: Equatable {
        let id: UUID
        let name: String
        let normalizedName: String
        let artKey: String
        let storageRaw: String
        let purchaseDay: Int32
        let expiryDay: Int32
        let expirySourceRaw: String
        let inventoryEpochContextRaw: String
        let deltas: [Int64]
        let reasons: [String]
        let stockChangeIDs: [UUID]
        let storeScope: String
    }

    private func storedRoots() throws -> [StoredRoot] {
        let context = controller.newWriterContext()
        var result: Result<[StoredRoot], Error>!
        context.performAndWait {
            result = Result {
                let request = FridgeItemRecord.fetchRequest()
                return try context.fetch(request).map { record in
                    let store = StoreRouting.store(of: record)
                    let events = record.stockChanges.sorted {
                        ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                    }
                    return StoredRoot(
                        id: record.id ?? HouseholdRecord.unidentifiable,
                        name: record.name ?? "",
                        normalizedName: record.normalizedName ?? "",
                        artKey: record.artKey ?? "",
                        storageRaw: record.storageRaw ?? "",
                        purchaseDay: record.purchaseDay,
                        expiryDay: record.expiryDay,
                        expirySourceRaw: record.expirySourceRaw ?? "",
                        inventoryEpochContextRaw: record.inventoryEpochContextRaw ?? "",
                        deltas: events.map(\.delta),
                        reasons: events.compactMap(\.reasonRaw),
                        stockChangeIDs: events.compactMap(\.id),
                        storeScope: store
                            .flatMap { self.controller.scope(of: $0)?.rawValue } ?? "unrouted")
                }
                // Sorted here rather than by a fetch descriptor, so the order is
                // the same UUID byte order the reducers use.
                .sorted { UUIDOrder.isBefore($0.id, $1.id) }
            }
        }
        return try result.get()
    }

    /// Every persisted merge claim, as sorted endpoint pairs.
    private func storedClaims() throws -> [[UUID]] {
        let context = controller.newWriterContext()
        var result: Result<[[UUID]], Error>!
        context.performAndWait {
            result = Result {
                try context.fetch(ItemMergeRecord.fetchRequest()).compactMap { record in
                    guard let left = record.leftItemID, let right = record.rightItemID else {
                        return nil
                    }
                    return [left, right]
                }
                .sorted { UUIDOrder.isBefore($0[0], $1[0]) }
            }
        }
        return try result.get()
    }

    private func initialEpochID(of household: UUID) throws -> UUID {
        let context = controller.newWriterContext()
        var result: Result<UUID, Error>!
        context.performAndWait {
            result = Result {
                let request = HouseholdRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", household as NSUUID)
                guard let epoch = try context.fetch(request).first?.initialInventoryEpochID else {
                    throw MissingRecord()
                }
                return epoch
            }
        }
        return try result.get()
    }

    /// Writes a record straight into the graph, which is what a remote import
    /// looks like from the repository's side.
    private func insertRemotely(_ body: @escaping (NSManagedObjectContext,
                                                   HouseholdRecord) throws -> [NSManagedObject])
    throws {
        let context = controller.newWriterContext()
        var result: Result<Void, Error>!
        let household = householdID!
        context.performAndWait {
            result = Result {
                let request = HouseholdRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", household as NSUUID)
                guard let record = try context.fetch(request).first else {
                    throw MissingRecord()
                }
                let inserted = try body(context, record)
                try StoreRouting.assign(inserted, to: self.controller.privateStore, in: context)
                try context.save()
            }
        }
        try result.get()
    }

    // MARK: - Every purchase gets a fresh causal root

    func testAPurchaseCreatesOneFrontierStampedRootAndOneAcquiredOperation() async throws {
        let projection = try await addManual(draft("Whole Milk", quantity: 2))

        XCTAssertEqual(projection.items.map(\.name), ["Whole Milk"])
        XCTAssertEqual(projection.items.first?.quantity, 2)

        let roots = try storedRoots()
        XCTAssertEqual(roots.count, 1)
        let root = try XCTUnwrap(roots.first)
        XCTAssertEqual(root.normalizedName, NameKey.normalize("Whole Milk"))
        XCTAssertEqual(root.deltas, [2])
        XCTAssertEqual(root.reasons, [StockReason.acquired.rawValue])
        XCTAssertEqual(root.purchaseDay, Self.today.ordinal)
        XCTAssertEqual(root.inventoryEpochContextRaw,
                       InventoryEpochCodec.encode([try initialEpochID(of: householdID)]))
        XCTAssertEqual(root.storeScope, HouseholdDatabaseScope.privateDatabase.rawValue)
    }

    /// A member-created child is assigned to the shared store explicitly;
    /// nothing relies on Core Data picking a default.
    func testAReceivedHouseholdsPurchaseIsAssignedToTheSharedStore() async throws {
        let received = try makeHousehold(in: controller.sharedStore, name: "Shared")

        try await addManual(draft("Whole Milk"), to: received)

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.storeScope),
                       [HouseholdDatabaseScope.sharedDatabase.rawValue])
    }

    func testEveryReceiptRowGetsItsOwnRootInOneAtomicSave() async throws {
        let projection = try await addRows([
            draft("Whole Milk", id: Self.id(1), quantity: 2),
            draft("Eggs", id: Self.id(2), quantity: 12, art: .eggs, expiresInDays: 12),
        ])

        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(try storedRoots().map(\.id), [Self.id(1), Self.id(2)])
    }

    /// The multirow save is atomic, so a row the repository refuses takes the
    /// whole receipt with it rather than leaving half a purchase behind.
    func testAConflictingRowFailsTheWholeReceipt() async throws {
        let stockChangeID = Self.id(10)
        try await addManual(draft("Whole Milk", id: Self.id(1), stockChangeID: stockChangeID,
                                  quantity: 2))

        do {
            _ = try await addRows([
                draft("Eggs", id: Self.id(3), quantity: 12, art: .eggs),
                // Same command id, different quantity: an integrity error, not
                // a second purchase.
                draft("Whole Milk", id: Self.id(1), stockChangeID: stockChangeID, quantity: 99),
            ])
            XCTFail("a conflicting payload must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryRepositoryError, .conflictingRetry(stockChangeID))
        }

        XCTAssertEqual(try storedRoots().map(\.id), [Self.id(1)],
                       "only the earlier purchase survives; neither receipt row landed")
        XCTAssertEqual(try storedRoots().first?.deltas, [2])
    }

    func testAnIdenticalRetryIsANoOp() async throws {
        let rows = [
            draft("Whole Milk", id: Self.id(1), stockChangeID: Self.id(11), quantity: 2),
            draft("Eggs", id: Self.id(2), stockChangeID: Self.id(12), quantity: 12, art: .eggs),
        ]
        try await addRows(rows)

        let replayed = try await addRows(rows)

        XCTAssertEqual(try storedRoots().count, 2)
        XCTAssertEqual(replayed.items.count, 2)
        XCTAssertEqual(replayed.items.map(\.quantity).sorted(), [2, 12])
    }

    /// The occurrence instant is part of the immutable payload: the reducer's
    /// corrupt-id tie-break sorts on it, so a second command reusing the id with
    /// a different instant is an integrity error rather than a silent no-op.
    func testARetryWithADifferentOccurrenceInstantIsAConflict() async throws {
        let stockChangeID = Self.id(11)
        let milk = draft("Whole Milk", id: Self.id(1), stockChangeID: stockChangeID, quantity: 2)
        try await addManual(milk)

        do {
            _ = try await addManual(
                draft("Whole Milk", id: Self.id(1), stockChangeID: stockChangeID, quantity: 2,
                      occurredAt: Self.occurredAt.addingTimeInterval(60)))
            XCTFail("a different occurrence instant must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryRepositoryError, .conflictingRetry(stockChangeID))
        }

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1)], "the stored purchase is untouched")
        XCTAssertEqual(roots.first?.deltas, [2])
    }

    /// A crash between the two rows leaves one written; the retry fills in only
    /// what is missing.
    func testAPartialRetryWritesOnlyTheMissingRow() async throws {
        let milk = draft("Whole Milk", id: Self.id(1), stockChangeID: Self.id(11), quantity: 2)
        let eggs = draft("Eggs", id: Self.id(2), stockChangeID: Self.id(12), quantity: 12,
                         art: .eggs)
        try await addManual(milk)

        try await addRows([milk, eggs])

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1), Self.id(2)])
        XCTAssertEqual(roots.map(\.deltas), [[2], [12]])
    }

    /// A double-tap on Confirm submits one preallocated draft twice before the
    /// first save returns. Each command opens its own writer context, so
    /// nothing in Core Data orders their duplicate checks: unserialized, both
    /// see no existing operation and insert the same item and StockChange ids,
    /// which no uniqueness constraint can catch because CloudKit forbids them.
    func testConcurrentSubmissionsOfOneDraftWriteItOnce() async throws {
        let probe = OverlapProbe()
        let probed = CoreDataInventoryRepository(persistence: controller, capabilities: probe)
        let command = AddManualItemCommand(
            householdID: householdID, commandID: UUID(),
            draft: draft("Whole Milk", id: Self.id(1), stockChangeID: Self.id(11), quantity: 2))

        async let first = probed.addManualItem(command, today: Self.today)
        async let second = probed.addManualItem(command, today: Self.today)
        let projections = try await [first, second]

        XCTAssertEqual(probe.peakOverlap, 1, "two command transactions overlapped")
        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1)], "the draft was written twice")
        XCTAssertEqual(roots.map(\.deltas), [[2]])
        // The second command is the no-op an identical retry always is, and it
        // still reports the same inventory.
        XCTAssertEqual(projections.map { $0.items.map(\.quantity) }, [[2], [2]])
    }

    // MARK: - Same-name convergence

    func testASameNamePurchaseKeepsBothRootsAndProjectsOneRow() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), quantity: 2))

        let projection = try await addManual(draft("Whole Milk", id: Self.id(2), quantity: 3))

        XCTAssertEqual(try storedRoots().count, 2, "a purchase never pays down an older root")
        XCTAssertEqual(projection.items.count, 1)
        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.quantity, 5)
        XCTAssertEqual(item.id, Self.id(1), "the lowest-id member is canonical")
        XCTAssertEqual(item.memberIDs, [Self.id(1), Self.id(2)])
    }

    /// Untouched scan guesses and form defaults must not overwrite metadata the
    /// existing item already established (ADR 0011).
    func testASameNamePurchaseCopiesCanonicalMetadataWhenNothingWasEdited() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), art: .milk, storage: .fridge,
                                  expiresInDays: 5))

        let projection = try await addManual(draft("Whole Milk", id: Self.id(2), art: .yogurt,
                                                   storage: .freezer, expiresInDays: 40))

        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.artKey, ItemID.milk.rawValue)
        XCTAssertEqual(item.storage, .fridge)
        XCTAssertEqual(item.expiryDay, Self.today.adding(days: 5))

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.artKey), [ItemID.milk.rawValue, ItemID.milk.rawValue])
        XCTAssertEqual(roots.map(\.expiryDay),
                       [Self.today.adding(days: 5)!.ordinal, Self.today.adding(days: 5)!.ordinal])
    }

    func testOnlyExplicitlyEditedFieldsReachTheCanonicalMember() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), art: .milk, storage: .fridge,
                                  expiresInDays: 5))

        let projection = try await addManual(
            draft("Whole Milk", id: Self.id(2), art: .yogurt, storage: .freezer,
                  expiresInDays: 40, explicit: [.storage, .expiryDay]))

        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.storage, .freezer, "an explicit edit applies")
        XCTAssertEqual(item.expiryDay, Self.today.adding(days: 40))
        XCTAssertEqual(item.artKey, ItemID.milk.rawValue, "an untouched guess does not")

        let canonical = try XCTUnwrap(try storedRoots().first { $0.id == Self.id(1) })
        XCTAssertEqual(canonical.storageRaw, StorageLocation.freezer.rawValue)
        XCTAssertEqual(canonical.expiryDay, Self.today.adding(days: 40)!.ordinal)
        XCTAssertEqual(canonical.expirySourceRaw, ExpirySource.userSet.rawValue,
                       "a date the user chose is never overwritten by a later guess")
    }

    func testTwoSameNameRowsInOneReceiptEstablishMetadataOnce() async throws {
        let projection = try await addRows([
            draft("Whole Milk", id: Self.id(1), quantity: 2, art: .milk, expiresInDays: 5),
            draft("Whole Milk", id: Self.id(2), quantity: 1, art: .yogurt, expiresInDays: 40),
        ])

        XCTAssertEqual(projection.items.count, 1)
        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.artKey, ItemID.milk.rawValue)
        XCTAssertEqual(try storedRoots().count, 2)
    }

    // MARK: - Durable merge claims

    func testReconciliationPersistsTheClaimWithoutMovingAnyHistory() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), stockChangeID: Self.id(11),
                                  quantity: 2))
        try await addManual(draft("Whole Milk", id: Self.id(2), stockChangeID: Self.id(12),
                                  quantity: 3))

        let written = try await reconciler.reconcile(householdID: householdID, today: Self.today)

        XCTAssertEqual(written, 1)
        XCTAssertEqual(try storedClaims(), [[Self.id(1), Self.id(2)]])
        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1), Self.id(2)])
        XCTAssertEqual(roots.map(\.stockChangeIDs), [[Self.id(11)], [Self.id(12)]],
                       "no operation was transferred between roots")
    }

    func testReconciliationIsIdempotent() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), quantity: 2))
        try await addManual(draft("Whole Milk", id: Self.id(2), quantity: 3))
        _ = try await reconciler.reconcile(householdID: householdID, today: Self.today)

        let second = try await reconciler.reconcile(householdID: householdID, today: Self.today)

        XCTAssertEqual(second, 0)
        XCTAssertEqual(try storedClaims().count, 1)
    }

    /// The link is what makes a late operation from an offline member count:
    /// it lands on its own physical root and still moves the one logical row.
    func testALateOperationOnEitherMemberChangesTheAggregate() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), quantity: 2))
        try await addManual(draft("Whole Milk", id: Self.id(2), quantity: 3))
        _ = try await reconciler.reconcile(householdID: householdID, today: Self.today)

        try insertRemotely { context, household in
            guard let root = household.items.first(where: { $0.id == Self.id(2) }) else {
                throw MissingRecord()
            }
            let eaten = StockChangeRecord(context: context)
            eaten.id = Self.id(20)
            eaten.delta = -1
            eaten.reasonRaw = StockReason.eaten.rawValue
            eaten.occurredAt = Self.occurredAt
            eaten.item = root
            return [eaten]
        }

        let projection = try await repository.projection(of: householdID, today: Self.today)
        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.quantity, 4)
    }

    // MARK: - The causal barrier

    func testARootFromASupersededContextLeavesHomeButStaysInHistory() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), quantity: 2))
        let initialEpoch = try initialEpochID(of: householdID)

        try insertRemotely { context, household in
            let clear = HouseholdClearRecord(context: context)
            clear.id = Self.id(30)
            clear.epochID = Self.id(31)
            clear.parentEpochIDsRaw = InventoryEpochCodec.encode([initialEpoch])
            clear.revision = 1
            clear.occurredAt = Self.occurredAt
            clear.household = household
            return [clear]
        }

        let projection = try await repository.projection(of: householdID, today: Self.today)
        XCTAssertTrue(projection.items.isEmpty)
        XCTAssertEqual(projection.physicalItems.map(\.id), [Self.id(1)],
                       "history survives a clear; only the projection moves on")
    }

    /// A purchase made after a clear captures the new leaf, so it is not swept
    /// away by the clear that came before it.
    func testAPurchaseAfterAClearCapturesTheNewFrontier() async throws {
        let initialEpoch = try initialEpochID(of: householdID)
        try insertRemotely { context, household in
            let clear = HouseholdClearRecord(context: context)
            clear.id = Self.id(30)
            clear.epochID = Self.id(31)
            clear.parentEpochIDsRaw = InventoryEpochCodec.encode([initialEpoch])
            clear.revision = 1
            clear.occurredAt = Self.occurredAt
            clear.household = household
            return [clear]
        }

        let projection = try await addManual(draft("Whole Milk", id: Self.id(1)))

        XCTAssertEqual(projection.items.map(\.id), [Self.id(1)])
        XCTAssertEqual(try storedRoots().first?.inventoryEpochContextRaw,
                       InventoryEpochCodec.encode([Self.id(31)]))
    }

    // MARK: - Refusals write nothing

    func testCapabilityDenialWritesNothing() async throws {
        let denied = CoreDataInventoryRepository(
            persistence: controller, capabilities: FakeStoreCapabilities(canModify: false))

        do {
            _ = try await denied.addManualItem(
                AddManualItemCommand(householdID: householdID, commandID: UUID(),
                                     draft: draft("Whole Milk")),
                today: Self.today)
            XCTFail("a denied capability must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryRepositoryError, .permissionDenied)
        }

        XCTAssertTrue(try storedRoots().isEmpty)
    }

    /// Editing an existing canonical member is a different CloudKit permission
    /// from inserting, and being refused it must not leave the new root behind.
    func testDeniedCanonicalUpdateWritesNothing() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), storage: .fridge))
        let denied = CoreDataInventoryRepository(
            persistence: controller,
            capabilities: FakeStoreCapabilities(canModify: true, canUpdate: false))

        do {
            _ = try await denied.addManualItem(
                AddManualItemCommand(householdID: householdID, commandID: UUID(),
                                     draft: draft("Whole Milk", id: Self.id(2),
                                                  storage: .freezer, explicit: [.storage])),
                today: Self.today)
            XCTFail("a denied update must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryRepositoryError, .permissionDenied)
        }

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1)])
        XCTAssertEqual(roots.first?.storageRaw, StorageLocation.fridge.rawValue)
    }

    func testAStaleHouseholdSelectionWritesNothing() async throws {
        do {
            _ = try await addManual(draft("Whole Milk"), to: UUID())
            XCTFail("a household that is gone must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryRepositoryError, .householdUnavailable)
        }

        XCTAssertTrue(try storedRoots().isEmpty)
    }

    func testAnInvalidDraftWritesNothing() async throws {
        do {
            _ = try await addManual(draft("   "))
            XCTFail("a nameless item must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryCommandError, .emptyItemName)
        }

        XCTAssertTrue(try storedRoots().isEmpty)
    }

    /// A quantity is any positive `Int64` (ADR 0004), so a same-name purchase
    /// can leave the representable total. Saving it would report success and
    /// then hand `StockReducer` a sum it must call corrupt — taking a group the
    /// user can still see off Home, permanently, because the `acquired`
    /// operation behind it is immutable. The command is refused instead.
    func testAPurchaseThatOverflowsItsGroupWritesNothing() async throws {
        try await addManual(draft("Rice", id: Self.id(1), stockChangeID: Self.id(11),
                                  quantity: .max))

        do {
            _ = try await addManual(draft("rice", id: Self.id(2), stockChangeID: Self.id(12),
                                          quantity: 1))
            XCTFail("a total beyond the representable range must fail the command")
        } catch {
            XCTAssertEqual(error as? InventoryCommandError, .quantityOutOfRange)
        }

        let roots = try storedRoots()
        XCTAssertEqual(roots.map(\.id), [Self.id(1)], "the refused purchase left a root behind")
        let projection = try await repository.projection(of: householdID, today: Self.today)
        XCTAssertEqual(projection.items.map(\.quantity), [.max], "the group stayed visible")
        XCTAssertTrue(projection.stockIssues.isEmpty)
    }

    // MARK: - What must never be persisted

    func testReceiptTextNeverLeavesTheReviewDraft() async throws {
        let receiptText = "TJ WHL MLK 1GAL"
        let parsed = ParsedItem(id: .milk, name: "Whole Milk", receiptText: receiptText,
                                quantity: 1, shelfLifeDays: 7)
        let row = PurchaseDraft(reviewing: parsed, itemID: Self.id(1), stockChangeID: Self.id(11),
                                purchaseDay: Self.today, occurredAt: Self.occurredAt)

        try await addRows([row])

        let stored = try storedRoots()
        XCTAssertEqual(stored.count, 1)
        for root in stored {
            for value in [root.name, root.normalizedName, root.artKey, root.storageRaw,
                          root.expirySourceRaw, root.inventoryEpochContextRaw] {
                XCTAssertFalse(value.contains(receiptText), "receipt text reached persistence")
            }
        }
    }

    // MARK: - Corrupt data

    /// One unreadable row is omitted and reported; the rows around it still
    /// render.
    func testACorruptRootIsOmittedWithoutHidingValidInventory() async throws {
        try await addManual(draft("Whole Milk", id: Self.id(1), quantity: 2))
        try insertRemotely { context, household in
            let broken = FridgeItemRecord(context: context)
            broken.id = Self.id(2)
            broken.name = "Eggs"
            // No normalized name, art, storage, expiry source, or context: the
            // shape a partially imported record can take.
            broken.household = household
            return [broken]
        }

        let projection = try await repository.projection(of: householdID, today: Self.today)

        XCTAssertEqual(projection.items.map(\.id), [Self.id(1)])
        XCTAssertEqual(projection.issues.map(\.id), [Self.id(2)])
        XCTAssertEqual(projection.issues.first?.category, .missingValue)
    }

    // MARK: - Seeding through the repository

    #if DEBUG
    /// The debug seed is an ordinary confirmation: every preset row becomes a
    /// fresh root with one `acquired` operation, and Home reads the result as
    /// snapshots like any other purchase.
    func testTheDebugSeedGoesThroughThePurchasePath() async throws {
        let drafts = PreviewData.seedPurchases(today: Self.today, now: Self.occurredAt)

        let projection = try await addRows(drafts)

        XCTAssertEqual(projection.items.count, drafts.count)
        XCTAssertEqual(try storedRoots().count, drafts.count)
        XCTAssertEqual(Set(try storedRoots().map(\.reasons)),
                       [[StockReason.acquired.rawValue]])
    }
    #endif
}

/// The seeded record a helper expected is not there — a bug in the test, not
/// in the repository.
private struct MissingRecord: Error {}

/// Counts how many command transactions are inside the repository at once, and
/// holds each one open long enough that an unserialized second submission
/// really does reach its duplicate check before the first saves.
private final class OverlapProbe: StoreCapabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    var peakOverlap: Int { lock.withLock { peak } }

    func canModifyManagedObjects(in store: NSPersistentStore) -> Bool {
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
        // On the writer context's own queue, so this delays only this
        // transaction — which is the point.
        Thread.sleep(forTimeInterval: 0.05)
        lock.withLock { active -= 1 }
        return true
    }

    func canUpdateRecord(forManagedObjectWith objectID: NSManagedObjectID) -> Bool { true }
}

