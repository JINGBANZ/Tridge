import CoreData
import Foundation
import XCTest
@testable import Tridge

/// Persistent-history consumption: one independent stream per store, this app's
/// own transactions filtered out of the effects while the token still advances
/// past them, and a token that moves only after the batch has been applied.
final class PersistentHistoryTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var tokens: HistoryTokenStore!
    private var repository: CoreDataInventoryRepository!
    private var householdID: UUID!

    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!
    private static let scope = AccountScopeHash(digest: String(repeating: "c", count: 64))!
    private static let otherScope = AccountScopeHash(digest: String(repeating: "d", count: 64))!

    /// A recording of what one history pass asked for.
    private actor Recorder {
        private(set) var reconciled: [UUID] = []
        private(set) var refreshed: [Set<UUID>] = []
        private var failure: Error?

        func fail(with error: Error?) { failure = error }

        func reconcile(_ householdID: UUID) throws {
            if let failure { throw failure }
            reconciled.append(householdID)
        }

        func refresh(_ householdIDs: Set<UUID>) { refreshed.append(householdIDs) }
    }

    private var recorder: Recorder!
    private var processor: PersistentHistoryProcessor!

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PersistentHistoryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope, baseDirectory: baseDirectory))
        defaultsSuite = "PersistentHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        tokens = HistoryTokenStore(accountScope: Self.scope, defaults: defaults)
        repository = CoreDataInventoryRepository(persistence: controller,
                                                 capabilities: FakeStoreCapabilities())
        householdID = try makeHousehold(in: controller.privateStore)

        let recorder = Recorder()
        self.recorder = recorder
        processor = PersistentHistoryProcessor(
            persistence: controller, tokens: tokens,
            effects: HistoryEffects(
                reconcileDuplicates: { try await recorder.reconcile($0) },
                refreshSession: { await recorder.refresh($0) }))
    }

    override func tearDown() async throws {
        processor = nil
        repository = nil
        controller?.tearDown()
        controller = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
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

    /// Writes under an author this app never uses, which is what a CloudKit
    /// import looks like to the history stream.
    private func writeAsPeer(into store: NSPersistentStore, householdID: UUID,
                             name: String = "Milk") throws {
        let context = controller.container.newBackgroundContext()
        context.transactionAuthor = "remote.peer"
        var result: Result<Void, Error>!
        context.performAndWait {
            result = Result {
                let request = HouseholdRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
                request.affectedStores = [store]
                guard let household = try context.fetch(request).first else {
                    throw MissingHousehold()
                }
                let frontier = try household.inventoryFrontier()
                let root = FridgeItemRecord(context: context)
                root.id = UUID()
                root.name = name
                root.normalizedName = NameKey.normalize(name)
                root.inventoryEpochContextRaw = InventoryEpochCodec.encode(frontier)
                root.artKey = ItemID.milk.rawValue
                root.storageRaw = StorageLocation.fridge.rawValue
                root.purchaseDay = Self.today.ordinal
                root.expiryDay = Self.today.adding(days: 5)!.ordinal
                root.expirySourceRaw = ExpirySource.llmEstimate.rawValue
                root.createdAt = Date()
                root.modifiedAt = root.createdAt
                root.household = household

                let event = StockChangeRecord(context: context)
                event.id = UUID()
                event.delta = 1
                event.reasonRaw = StockReason.acquired.rawValue
                event.occurredAt = Date()
                event.item = root

                try StoreRouting.assign([root, event], to: store, in: context)
                try context.save()
            }
        }
        try result.get()
    }

    private func draft(_ name: String) -> PurchaseDraft {
        PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: name, quantity: 1,
                      artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: Self.today,
                      expiryDay: Self.today.adding(days: 5)!, expirySource: .llmEstimate,
                      explicitMetadataFields: [])
    }

    // MARK: - Tokens

    func testTokensAreIndependentPerStore() async throws {
        try writeAsPeer(into: controller.privateStore, householdID: householdID)
        await processor.processAll()

        let privateToken = tokens.token(forStoreIdentifier: controller.privateStore.identifier)
        XCTAssertNotNil(privateToken, "the private stream advanced")

        // The shared store had its own (empty) stream, so its token is whatever
        // its own transactions produced — never the private store's.
        let sharedToken = tokens.token(forStoreIdentifier: controller.sharedStore.identifier)
        if let sharedToken {
            XCTAssertNotEqual(sharedToken, privateToken)
        }
    }

    func testATokenIsScopedByAccountAndStore() throws {
        let store = HistoryTokenStore(accountScope: Self.scope, defaults: defaults)
        let otherAccount = HistoryTokenStore(accountScope: Self.otherScope, defaults: defaults)

        try writeAsPeer(into: controller.privateStore, householdID: householdID)
        let token = try XCTUnwrap(
            controller.container.persistentStoreCoordinator
                .currentPersistentHistoryToken(fromStores: [controller.privateStore]))
        store.save(token, forStoreIdentifier: controller.privateStore.identifier)

        XCTAssertNotNil(store.token(forStoreIdentifier: controller.privateStore.identifier))
        XCTAssertNil(store.token(forStoreIdentifier: controller.sharedStore.identifier),
                     "the other store has its own cursor")
        XCTAssertNil(otherAccount.token(forStoreIdentifier: controller.privateStore.identifier),
                     "another account never reads this one's cursor")
    }

    // MARK: - Filtering

    func testThisAppsOwnTransactionsProduceNoEffectsButStillAdvanceTheToken() async throws {
        _ = try await repository.addManualItem(
            AddManualItemCommand(householdID: householdID, commandID: UUID(),
                                 draft: draft("Whole Milk")),
            today: Self.today)

        await processor.processAll()

        let reconciled = await recorder.reconciled
        let refreshed = await recorder.refreshed
        XCTAssertTrue(reconciled.isEmpty, "a local save is already in the view context")
        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertNotNil(tokens.token(forStoreIdentifier: controller.privateStore.identifier),
                        "the cursor still moves past app-authored transactions")
    }

    func testARemoteTransactionReconcilesAndRefreshesItsHousehold() async throws {
        try writeAsPeer(into: controller.privateStore, householdID: householdID)

        await processor.processAll()

        let reconciled = await recorder.reconciled
        let refreshed = await recorder.refreshed
        XCTAssertEqual(reconciled, [householdID])
        XCTAssertEqual(refreshed, [[householdID]])
    }

    func testAProcessedBatchIsNotProcessedTwice() async throws {
        try writeAsPeer(into: controller.privateStore, householdID: householdID)
        await processor.processAll()
        await processor.processAll()

        let reconciled = await recorder.reconciled
        XCTAssertEqual(reconciled, [householdID], "the token moved past the batch")
    }

    // MARK: - Failure leaves the cursor alone

    func testAFailedPassLeavesTheTokenSoTheBatchIsRetried() async throws {
        try writeAsPeer(into: controller.privateStore, householdID: householdID)
        await recorder.fail(with: MissingHousehold())

        await processor.processAll()
        XCTAssertNil(tokens.token(forStoreIdentifier: controller.privateStore.identifier),
                     "an unapplied batch must not advance the cursor")

        await recorder.fail(with: nil)
        await processor.processAll()

        let reconciled = await recorder.reconciled
        XCTAssertEqual(reconciled, [householdID], "the same batch is retried and then applied")
        XCTAssertNotNil(tokens.token(forStoreIdentifier: controller.privateStore.identifier))
    }

    // MARK: - Store scoping

    func testAChangeInOneStoreDoesNotReportTheOthersHouseholds() async throws {
        let received = try makeHousehold(in: controller.sharedStore, name: "Their Fridge")
        try writeAsPeer(into: controller.sharedStore, householdID: received)

        await processor.processAll()

        let refreshed = await recorder.refreshed
        XCTAssertEqual(refreshed, [[received]],
                       "the private store's Household is not part of this batch")
    }
}

private struct MissingHousehold: Error {}
