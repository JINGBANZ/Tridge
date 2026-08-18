import CoreData
import XCTest
@testable import Tridge

/// Store loading and routing, with CloudKit disabled: these are the local
/// guarantees that must hold before any mirroring is switched on.
final class PersistenceControllerTests: XCTestCase {
    private var baseDirectory: URL!
    private var controllers: [PersistenceController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PersistenceControllerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers { controller.tearDown() }
        controllers = []
        try? FileManager.default.removeItem(at: baseDirectory)
        try super.tearDownWithError()
    }

    private func scope(_ character: Character = "a") -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: character, count: 64))!
    }

    private func makeController(for scope: AccountScopeHash) async throws -> PersistenceController {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
        controllers.append(controller)
        return controller
    }

    private func storeURL(_ scope: AccountScopeHash, _ database: HouseholdDatabaseScope) -> URL {
        scope.storePathComponents(for: database)
            .reduce(baseDirectory) { $0.appendingPathComponent($1) }
    }

    // MARK: - Launch

    func testBothStoresLoadAsOneIsolatedPair() async throws {
        let scope = scope()
        let controller = try await makeController(for: scope)

        XCTAssertNotIdentical(controller.privateStore, controller.sharedStore)
        XCTAssertEqual(controller.storeIdentifiers.count, 2)
        XCTAssertEqual(controller.scope(of: controller.privateStore), .privateDatabase)
        XCTAssertEqual(controller.scope(of: controller.sharedStore), .sharedDatabase)
        XCTAssertEqual(controller.store(for: .sharedDatabase), controller.sharedStore)
        XCTAssertEqual(controller.privateStore.url, storeURL(scope, .privateDatabase))
        XCTAssertEqual(controller.sharedStore.url, storeURL(scope, .sharedDatabase))
    }

    func testEachAccountOpensItsOwnFilesAndNeverTheOtherAccountsData() async throws {
        let first = try await makeController(for: scope("1"))
        let second = try await makeController(for: scope("2"))

        XCTAssertNotEqual(first.privateStore.url, second.privateStore.url)
        XCTAssertTrue(first.storeIdentifiers.isDisjoint(with: second.storeIdentifiers))
    }

    func testAStoreThatCannotOpenIsRetryableRatherThanFatal() async throws {
        // A partial private-only stack must never be exposed: commands would be
        // routed to a store that is not there.
        let scope = scope("c")
        let url = storeURL(scope, .sharedDatabase)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: url)

        do {
            let controller = try await PersistenceController.load(
                configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
            controllers.append(controller)
            XCTFail("a corrupt shared store must fail the whole stack")
        } catch let error as PersistenceController.LoadError {
            XCTAssertFalse(error.diagnosticID.contains(url.path), "diagnostics leak the path")
            let state = LaunchState(loadError: error)
            XCTAssertEqual(state, .persistenceUnavailable(diagnosticID: error.diagnosticID))
            XCTAssertTrue(state.isRetryable)
        }
    }

    func testTearingDownReleasesBothStoresWithoutDeletingEitherAccountsFiles() async throws {
        let scope = scope("d")
        let controller = try await makeController(for: scope)
        controller.tearDown()

        XCTAssertTrue(controller.container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL(scope, .privateDatabase).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL(scope, .sharedDatabase).path))
    }

    // MARK: - Contexts

    func testWriterContextsAreConfinedTaggedAndObjectTrumping() async throws {
        let controller = try await makeController(for: scope())

        for (context, author) in [(controller.newWriterContext(), "app.inventory"),
                                  (controller.newReconcilerContext(), "app.reconcile")] {
            XCTAssertEqual(context.concurrencyType, .privateQueueConcurrencyType)
            XCTAssertEqual(context.transactionAuthor, author)
            XCTAssertEqual((context.mergePolicy as? NSMergePolicy)?.mergeType,
                           .mergeByPropertyObjectTrumpMergePolicyType)
        }

        XCTAssertEqual(controller.viewContext.concurrencyType, .mainQueueConcurrencyType)
        XCTAssertTrue(controller.viewContext.automaticallyMergesChangesFromParent)
        XCTAssertEqual((controller.viewContext.mergePolicy as? NSMergePolicy)?.mergeType,
                       .mergeByPropertyStoreTrumpMergePolicyType)
    }

    // MARK: - Store routing

    func testAnInsertedHouseholdTakesItsOwnershipFromTheStoreItIsAssignedTo() async throws {
        let controller = try await makeController(for: scope())
        let context = controller.newWriterContext()

        try await context.perform {
            let owned = self.makeHousehold(in: context, name: "Owned")
            let received = self.makeHousehold(in: context, name: "Received")
            try StoreRouting.assign([owned], to: controller.privateStore, in: context)
            try StoreRouting.assign([received], to: controller.sharedStore, in: context)
            try context.save()

            XCTAssertIdentical(StoreRouting.store(of: owned), controller.privateStore)
            XCTAssertIdentical(StoreRouting.store(of: received), controller.sharedStore)
            XCTAssertEqual(controller.ownership(of: owned), .owned)
            XCTAssertEqual(controller.ownership(of: received), .received)
        }
    }

    func testAnObjectFromTheOtherStoreIsRejectedBeforeItCanBeLinked() async throws {
        let controller = try await makeController(for: scope())
        let context = controller.newWriterContext()

        try await context.perform {
            let household = self.makeHousehold(in: context, name: "Owned")
            try StoreRouting.assign([household], to: controller.privateStore, in: context)
            try context.save()

            let item = self.makeItem(in: context, name: "Milk")
            try StoreRouting.assign([item], to: controller.sharedStore, in: context)
            try context.save()

            XCTAssertThrowsError(
                try StoreRouting.validate([item], belongTo: controller.privateStore)
            ) { error in
                XCTAssertEqual(error as? StoreRoutingError, .crossStoreRelationship)
            }
            XCTAssertNoThrow(try StoreRouting.validate([item], belongTo: controller.sharedStore))
        }
    }

    func testAMisroutedChildIsCaughtInsideTheTransactionThatInsertedIt() async throws {
        // The repository inserts and saves once, so both objects are new. A
        // temporary id has no store, so assignment resolves ids immediately —
        // otherwise this cross-store link would only surface as an uncatchable
        // exception at save time.
        let controller = try await makeController(for: scope())
        let context = controller.newWriterContext()

        try await context.perform {
            let household = self.makeHousehold(in: context, name: "Owned")
            let item = self.makeItem(in: context, name: "Milk")
            try StoreRouting.assign([household], to: controller.privateStore, in: context)
            try StoreRouting.assign([item], to: controller.sharedStore, in: context)

            XCTAssertThrowsError(
                try StoreRouting.validate([item], belongTo: controller.privateStore)
            ) { error in
                XCTAssertEqual(error as? StoreRoutingError, .crossStoreRelationship)
            }
            context.delete(item)
        }
    }

    private func makeItem(in context: NSManagedObjectContext, name: String) -> FridgeItemRecord {
        let item = FridgeItemRecord(context: context)
        item.id = UUID()
        item.name = name
        item.normalizedName = NameKey.normalize(name)
        item.createdAt = Date()
        item.modifiedAt = item.createdAt
        return item
    }

    private func makeHousehold(in context: NSManagedObjectContext, name: String) -> HouseholdRecord {
        let household = HouseholdRecord(context: context)
        household.id = UUID()
        household.name = name
        household.initialInventoryEpochID = UUID()
        household.createdAt = Date()
        household.modifiedAt = household.createdAt
        return household
    }
}
