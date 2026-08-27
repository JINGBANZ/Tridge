import CoreData
import XCTest
@testable import Tridge

/// Export and legacy erasure — the two things the data-controls section
/// promises, and the two places where being imprecise would either withhold a
/// user's history or delete something that was not theirs to delete.
final class HouseholdDataRightsTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var repository: CoreDataInventoryRepository!
    private var reconciler: DuplicateReconciler!
    private var householdID: UUID!

    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!
    private static let occurredAt = Date(timeIntervalSince1970: 1_787_097_600)
    private static let scope = AccountScopeHash(digest: String(repeating: "e", count: 64))!

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HouseholdDataRightsTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope, baseDirectory: baseDirectory))
        repository = CoreDataInventoryRepository(persistence: controller,
                                                 capabilities: FakeStoreCapabilities())
        reconciler = DuplicateReconciler(persistence: controller,
                                         capabilities: FakeStoreCapabilities())
        householdID = try makeHousehold()
    }

    override func tearDown() async throws {
        repository = nil
        reconciler = nil
        controller?.tearDown()
        controller = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private func makeHousehold(name: String = "Home") throws -> UUID {
        let context = controller.newWriterContext()
        var result: Result<UUID, Error>!
        context.performAndWait {
            result = Result {
                let household = HouseholdRecord(context: context)
                let id = UUID()
                household.id = id
                household.name = name
                household.initialInventoryEpochID = UUID()
                household.createdAt = Self.occurredAt
                household.modifiedAt = Self.occurredAt
                try StoreRouting.assign([household], to: controller.privateStore, in: context)
                try context.save()
                return id
            }
        }
        return try result.get()
    }

    private func draft(_ name: String, quantity: Int64 = 1) -> PurchaseDraft {
        PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: name, quantity: quantity,
                      artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: Self.today,
                      expiryDay: Self.today.adding(days: 5)!, expirySource: .llmEstimate,
                      explicitMetadataFields: [], occurredAt: Self.occurredAt)
    }

    @discardableResult
    private func add(_ drafts: [PurchaseDraft]) async throws -> HouseholdProjection {
        try await repository.addReviewedRows(
            AddReviewedRowsCommand(householdID: householdID, commandID: UUID(), rows: drafts),
            today: Self.today)
    }

    // MARK: - Export

    /// A fridge with something current, something deleted, and something a
    /// Clear All retired — the three kinds of history the export must carry.
    private func seedCompleteHistory() async throws {
        let deleted = draft("Yoghurt")
        _ = try await add([draft("Cleared Milk"), deleted])
        _ = try await repository.deleteItem(
            DeleteItemCommand(householdID: householdID, commandID: UUID(), itemID: deleted.itemID,
                              stockChangeID: UUID(), occurredAt: Self.occurredAt),
            today: Self.today)
        _ = try await repository.clearActiveHousehold(
            ClearHouseholdCommand(householdID: householdID, commandID: UUID(),
                                  clearRecordID: UUID(), epochID: UUID(),
                                  occurredAt: Self.occurredAt),
            today: Self.today)
        // Two same-name roots after the clear, so a permanent claim exists too.
        _ = try await add([draft("Eggs", quantity: 6)])
        _ = try await add([draft("Eggs", quantity: 6)])
        _ = try await reconciler.reconcile(householdID: householdID, today: Self.today)
    }

    func testExportCarriesCurrentAndRetiredHistoryAlike() async throws {
        try await seedCompleteHistory()
        let exporter = InventoryExporter(persistence: controller)

        let document = try await exporter.document(for: householdID, today: Self.today,
                                                   now: Self.occurredAt)

        XCTAssertEqual(document.householdName, "Home")
        XCTAssertEqual(document.items.map(\.name), ["Eggs"], "only Eggs is current")
        XCTAssertEqual(Set(document.physicalItems.map(\.name)),
                       ["Cleared Milk", "Yoghurt", "Eggs"],
                       "every root is exported, superseded and deleted included")
        XCTAssertTrue(document.stockOperations.contains { $0.reason == "deleted" })
        XCTAssertEqual(document.clearEvents.count, 1)
        XCTAssertEqual(document.clearEvents.first?.revision, 1)
        XCTAssertEqual(document.itemMerges.count, 1,
                       "the permanent exact-name claim travels with the history")
    }

    func testExportWritesAReadableFileAndNamesTheFridge() async throws {
        _ = try await add([draft("Milk", quantity: 2)])
        let exporter = InventoryExporter(persistence: controller)

        let url = try await exporter.exportDocument(for: householdID, today: Self.today,
                                                    now: Self.occurredAt)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Home Inventory.json")
        let restored = try InventoryExportDocument.decoded(from: Data(contentsOf: url))
        XCTAssertEqual(restored.items.map(\.name), ["Milk"])
        XCTAssertEqual(restored.items.first?.quantity, 2)
    }

    func testExportingAHouseholdThatIsGoneFails() async throws {
        let exporter = InventoryExporter(persistence: controller)

        do {
            _ = try await exporter.document(for: UUID(), today: Self.today)
            XCTFail("expected the export to refuse an unknown fridge")
        } catch let error as InventoryRepositoryError {
            XCTAssertEqual(error, .householdUnavailable)
        }
    }

    // MARK: - Legacy erasure

    /// A stand-in archive with the shipping build's exact names.
    ///
    /// A real SQLite store rather than a placeholder file, because the erasure
    /// path calls Core Data's own `destroyPersistentStore` and that has to be
    /// exercised for what it is.
    private func makeArchive(base: URL) throws {
        let model = try XCTUnwrap(TridgeModel.managedObjectModel)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, configuration: nil,
                                                       at: base, options: nil)
        try coordinator.remove(store)
        for suffix in LegacyInventoryArchive.sidecarSuffixes {
            let url = URL(fileURLWithPath: base.path + suffix)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try Data(suffix.utf8).write(to: url)
        }
    }

    private func archiveURL(_ name: String = "default.store") -> URL {
        baseDirectory.appendingPathComponent(name, isDirectory: false)
    }

    func testErasureRemovesExactlyTheBaseAndItsSidecars() throws {
        let base = archiveURL()
        try makeArchive(base: base)
        // A neighbouring file with a similar name must survive untouched.
        let neighbour = archiveURL("default.store.backup")
        try Data("keep".utf8).write(to: neighbour)
        let eraser = LegacyArchiveEraser(storeURL: base)
        XCTAssertTrue(eraser.hasRemnants)

        try eraser.erase()

        XCTAssertFalse(eraser.hasRemnants)
        for target in eraser.targets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path),
                      "the target set is never broadened")
    }

    func testAnAbsentArchiveIsSuccess() throws {
        let eraser = LegacyArchiveEraser(storeURL: archiveURL())

        XCTAssertFalse(eraser.hasRemnants)
        XCTAssertNoThrow(try eraser.erase(), "already gone is the same as done")
    }

    /// A crash can leave sidecars behind with the base already destroyed;
    /// Retry has to finish rather than refuse.
    func testSidecarsAloneAreStillRemoved() throws {
        let base = archiveURL()
        for suffix in LegacyInventoryArchive.sidecarSuffixes {
            try Data(suffix.utf8).write(to: URL(fileURLWithPath: base.path + suffix))
        }
        let eraser = LegacyArchiveEraser(storeURL: base)
        XCTAssertTrue(eraser.hasRemnants)

        try eraser.erase()

        XCTAssertFalse(eraser.hasRemnants)
    }

    func testASymbolicLinkIsRefusedRatherThanFollowed() throws {
        let real = archiveURL("something-else")
        try Data("precious".utf8).write(to: real)
        let base = archiveURL()
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: real)
        let eraser = LegacyArchiveEraser(storeURL: base)

        XCTAssertThrowsError(try eraser.erase()) { error in
            XCTAssertEqual(error as? LegacyArchiveEraser.Failure, .invalidTarget)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path),
                      "the link's destination is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    func testADirectoryTargetIsRefused() throws {
        let base = archiveURL()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let eraser = LegacyArchiveEraser(storeURL: base)

        XCTAssertThrowsError(try eraser.erase()) { error in
            XCTAssertEqual(error as? LegacyArchiveEraser.Failure, .invalidTarget)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    /// The current stores live under `HouseholdSharing/`. Nothing there is ever
    /// a legacy archive, whatever it is called.
    func testATargetInsideTheSharingStacksStorageIsRefused() throws {
        let directory = baseDirectory
            .appendingPathComponent(LegacyArchiveEraser.protectedDirectoryComponent,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("default.store", isDirectory: false)
        try makeArchive(base: base)
        let eraser = LegacyArchiveEraser(storeURL: base)

        XCTAssertThrowsError(try eraser.erase()) { error in
            XCTAssertEqual(error as? LegacyArchiveEraser.Failure, .invalidTarget)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    func testAnUnresolvableLocationIsRefused() {
        let eraser = LegacyArchiveEraser(storeURL: nil)

        XCTAssertFalse(eraser.hasRemnants)
        XCTAssertThrowsError(try eraser.erase()) { error in
            XCTAssertEqual(error as? LegacyArchiveEraser.Failure, .unresolvedLocation)
        }
    }

    func testErasureNeverTouchesACurrentStore() throws {
        let base = archiveURL()
        try makeArchive(base: base)
        let privateStoreURL = try XCTUnwrap(controller.privateStore.url)

        try LegacyArchiveEraser(storeURL: base).erase()

        XCTAssertTrue(FileManager.default.fileExists(atPath: privateStoreURL.path),
                      "a current Household store is never a target")
    }
}
