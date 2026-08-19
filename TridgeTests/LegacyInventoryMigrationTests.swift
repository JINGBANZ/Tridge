import CoreData
import SwiftData
import XCTest
@testable import Tridge

/// The upgrade from the shipping SwiftData build: cleanup that must happen even
/// without an account, a migration that must happen exactly once, and an archive
/// that must survive both.
@MainActor
final class LegacyInventoryMigrationTests: XCTestCase {
    private var baseDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var loader: StackLoader!
    private var identity: FakeAccountIdentity!
    private var monitor: StoreScopedSyncMonitor!
    private var archive: FakeLegacyArchive!
    private var effects: RecordingLegacyEffects!
    private var markers: UpgradeMarkers!
    private var coordinator: AccountSessionCoordinator!

    /// 2026-08-19 00:00 UTC, in a fixed zone so the expected days do not depend
    /// on where the test runs.
    private static let purchaseInstant = Date(timeIntervalSince1970: 1_787_097_600)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LegacyInventoryMigrationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "LegacyInventoryMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        loader = StackLoader(baseDirectory: baseDirectory)
        identity = FakeAccountIdentity(result: .success(Self.scope()))
        monitor = StoreScopedSyncMonitor()
        archive = FakeLegacyArchive(rows: [Self.row(name: "Whole Milk", quantity: 2)])
        effects = RecordingLegacyEffects()
        markers = UpgradeMarkers(defaults: defaults)
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

    /// A second coordinator over the same defaults and stores is what a relaunch
    /// of an upgraded installation looks like.
    private func makeCoordinator() -> AccountSessionCoordinator {
        AccountSessionCoordinator(
            identity: identity, syncMonitor: monitor,
            barrier: BootstrapBarrierStore(defaults: defaults),
            activeHouseholds: ActiveHouseholdStore(defaults: defaults),
            upgrade: LegacyInventoryUpgrade(archive: archive, markers: markers, effects: effects,
                                            calendar: { Self.calendar }),
            makePersistence: loader.closure)
    }

    private static func scope(_ character: Character = "a") -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: character, count: 64))!
    }

    private static func row(id: UUID = UUID(), name: String, quantity: Int = 1,
                            artKey: String = ItemID.milk.rawValue,
                            storageRaw: String = StorageLocation.fridge.rawValue,
                            expirySourceRaw: String = ExpirySource.llmEstimate.rawValue)
    -> LegacyInventoryRow {
        LegacyInventoryRow(id: id, name: name, artKey: artKey, quantity: quantity,
                           storageRaw: storageRaw, purchaseDate: purchaseInstant,
                           expiryDate: purchaseInstant.addingTimeInterval(5 * 86_400),
                           expirySourceRaw: expirySourceRaw)
    }

    /// Emits the setup and import a store reports on its first successful sync.
    private func completeInitialSync(of storeIdentifier: String) {
        for kind in [SyncEventKind.setup, .importChanges] {
            let id = "\(storeIdentifier).\(kind)"
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                      kind: kind, isComplete: false))
            monitor.receive(SyncEvent(identifier: id, storeIdentifier: storeIdentifier,
                                      kind: kind, isComplete: true, succeeded: true))
        }
    }

    /// Brings an empty account all the way to a bootstrapped `My Fridge`, which
    /// is what an upgrading installation's first launch does.
    private func startAndBootstrap() async throws {
        await coordinator.start()
        let session = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: session.context.privateStoreIdentifier)
        await waitUntil("the Active Household to resolve") {
            self.coordinator.activeHouseholdID != nil
        }
    }

    private func awaitMigration() async {
        await waitUntil("the migration to be recorded") {
            self.markers.hasMigratedLegacyInventory
                || self.coordinator.legacyMigrationFailure != nil
        }
    }

    // MARK: - Reading what was written

    private struct MigratedRow: Equatable {
        let id: UUID
        let name: String
        let normalizedName: String
        let artKey: String
        let storageRaw: String
        let expirySourceRaw: String
        let purchaseDay: Int32
        let expiryDay: Int32
        let inventoryEpochContextRaw: String
        let acquisitions: [Int64]
        let stockChangeIDs: [UUID]
    }

    private func migratedRows(in controller: PersistenceController) throws -> [MigratedRow] {
        let context = controller.newWriterContext()
        var result: Result<[MigratedRow], Error>!
        context.performAndWait {
            result = Result {
                let request = FridgeItemRecord.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
                return try context.fetch(request).map { record in
                    let acquired = record.stockChanges
                        .filter { $0.reasonRaw == StockReason.acquired.rawValue }
                    return MigratedRow(
                        id: record.id ?? HouseholdRecord.unidentifiable,
                        name: record.name ?? "",
                        normalizedName: record.normalizedName ?? "",
                        artKey: record.artKey ?? "",
                        storageRaw: record.storageRaw ?? "",
                        expirySourceRaw: record.expirySourceRaw ?? "",
                        purchaseDay: record.purchaseDay,
                        expiryDay: record.expiryDay,
                        inventoryEpochContextRaw: record.inventoryEpochContextRaw ?? "",
                        acquisitions: acquired.map(\.delta).sorted(),
                        stockChangeIDs: record.stockChanges.compactMap(\.id))
                }
            }
        }
        return try result.get()
    }

    private func initialEpochID(of householdID: UUID,
                                in controller: PersistenceController) throws -> UUID {
        let context = controller.newWriterContext()
        var result: Result<UUID, Error>!
        context.performAndWait {
            result = Result {
                let request = HouseholdRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
                guard let epoch = try context.fetch(request).first?.initialInventoryEpochID else {
                    throw MissingSeededRecord()
                }
                return epoch
            }
        }
        return try result.get()
    }

    // MARK: - Legacy side effects

    /// The cleanup runs before iCloud is consulted, so an installation that will
    /// never reach the migration still stops notifying for a moved inventory.
    func testLegacyRemindersAreClearedWhileSignedOut() async {
        identity.result = .failure(AccountIdentityError.unavailable(.noAccount))

        await coordinator.start()

        XCTAssertEqual(effects.clearCount, 1)
        XCTAssertTrue(markers.hasCleanedLegacyEffects)
        XCTAssertEqual(coordinator.launchState, .iCloudAccountRequired(.noAccount))
        XCTAssertTrue(loader.controllers.isEmpty, "a store opened before the cleanup ran")
    }

    func testLegacyRemindersAreClearedExactlyOnceAcrossLaunches() async throws {
        try await startAndBootstrap()
        XCTAssertEqual(effects.clearCount, 1)

        await coordinator.shutDown()
        coordinator = makeCoordinator()
        await coordinator.start()

        XCTAssertEqual(effects.clearCount, 1)
    }

    // MARK: - Migration

    func testActiveRowsMigrateIntoTheFirstOwnedHouseholdAsPurchaseRoots() async throws {
        let milk = UUID()
        let eggs = UUID()
        archive.rows = [Self.row(id: milk, name: "Whole Milk", quantity: 2),
                        Self.row(id: eggs, name: "Eggs", quantity: 12,
                                 artKey: ItemID.eggs.rawValue,
                                 storageRaw: StorageLocation.pantry.rawValue,
                                 expirySourceRaw: ExpirySource.userSet.rawValue)]

        try await startAndBootstrap()
        await awaitMigration()

        let session = try XCTUnwrap(coordinator.session)
        let householdID = try XCTUnwrap(coordinator.activeHouseholdID)
        let rows = try migratedRows(in: session.persistence)
        XCTAssertNil(coordinator.legacyMigrationFailure)
        XCTAssertEqual(rows.map(\.id), [eggs, milk])
        XCTAssertEqual(rows.map(\.name), ["Eggs", "Whole Milk"])
        XCTAssertEqual(rows.map(\.normalizedName), ["eggs", "whole milk"])
        XCTAssertEqual(rows.map(\.acquisitions), [[12], [2]])
        // The legacy id is the acquisition's command id, which is what makes a
        // retry recognizable.
        XCTAssertEqual(rows.map(\.stockChangeIDs), [[eggs], [milk]])
        XCTAssertEqual(rows.map(\.artKey), [ItemID.eggs.rawValue, ItemID.milk.rawValue])
        XCTAssertEqual(rows.map(\.storageRaw),
                       [StorageLocation.pantry.rawValue, StorageLocation.fridge.rawValue])
        XCTAssertEqual(rows.map(\.expirySourceRaw),
                       [ExpirySource.userSet.rawValue, ExpirySource.llmEstimate.rawValue])
        // Displayed days, converted through the captured calendar.
        XCTAssertEqual(rows.first?.purchaseDay, InventoryDay(year: 2026, month: 8, day: 19)?.ordinal)
        XCTAssertEqual(rows.first?.expiryDay, InventoryDay(year: 2026, month: 8, day: 24)?.ordinal)
        // Every root captures the Household's current causal frontier.
        let epoch = try initialEpochID(of: householdID, in: session.persistence)
        XCTAssertEqual(Set(rows.map(\.inventoryEpochContextRaw)),
                       [InventoryEpochCodec.encode([epoch])!])
        XCTAssertEqual(markers.migrationDestination,
                       UpgradeMarkers.MigrationDestination(accountScope: Self.scope(),
                                                           householdID: householdID))
    }

    func testASecondLaunchDoesNotMigrateTheArchiveAgain() async throws {
        try await startAndBootstrap()
        await awaitMigration()
        let firstReadCount = archive.readCount

        await coordinator.shutDown()
        coordinator = makeCoordinator()
        try await startAndBootstrap()

        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(archive.readCount, firstReadCount, "the archive was read again")
        XCTAssertEqual(try migratedRows(in: session.persistence).count, 1)
    }

    /// The marker is installation-wide on purpose: signing into another iCloud
    /// account must not hand it the same archive.
    func testAnotherAccountDoesNotReceiveTheSameArchive() async throws {
        try await startAndBootstrap()
        await awaitMigration()
        let firstHousehold = try XCTUnwrap(coordinator.activeHouseholdID)

        identity.result = .success(Self.scope("b"))
        coordinator.accountDidChange()
        await waitUntil("the next account's session") { self.coordinator.session != nil }
        let second = try XCTUnwrap(coordinator.session)
        completeInitialSync(of: second.context.privateStoreIdentifier)
        await waitUntil("the next account to bootstrap") {
            self.coordinator.activeHouseholdID != nil
        }

        XCTAssertTrue(try migratedRows(in: second.persistence).isEmpty)
        XCTAssertEqual(markers.migrationDestination?.accountScope, Self.scope())
        XCTAssertEqual(markers.migrationDestination?.householdID, firstHousehold)
    }

    /// A Household received through someone else's share is never the
    /// destination, and the upgrade does not silently move the user's selection.
    func testAReceivedHouseholdIsNeverTheDestination() async throws {
        let received = try await seedHousehold(name: "Theirs", ownership: .received)

        await coordinator.start()
        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(coordinator.activeHouseholdID, received)
        // Creating the owned destination waits for the same evidence bootstrap
        // waits for.
        XCTAssertTrue(try migratedRows(in: session.persistence).isEmpty)

        completeInitialSync(of: session.context.privateStoreIdentifier)
        await awaitMigration()

        XCTAssertEqual(coordinator.activeHouseholdID, received, "the upgrade switched fridges")
        let owned = try XCTUnwrap(coordinator.households.first { $0.ownership == .owned })
        XCTAssertEqual(owned.name, HouseholdSelection.defaultHouseholdName)
        XCTAssertEqual(markers.migrationDestination?.householdID, owned.id)
        XCTAssertEqual(try migratedRows(in: session.persistence).count, 1)
    }

    // MARK: - Failure

    func testACorruptRowWritesNothingAndKeepsTheArchive() async throws {
        archive.rows = [Self.row(name: "Whole Milk"), Self.row(name: "  "),
                        Self.row(name: "Eggs")]

        try await startAndBootstrap()
        await awaitMigration()

        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(coordinator.legacyMigrationFailure,
                       LegacyMigrationFailure(diagnosticID: "legacy.row.invalidName"))
        XCTAssertTrue(try migratedRows(in: session.persistence).isEmpty)
        XCTAssertFalse(markers.hasMigratedLegacyInventory)
        XCTAssertTrue(archive.exists, "the archive was not retained for a retry")
        XCTAssertFalse(coordinator.showsMigrationNotice)
        // Inventory itself is usable — the failure is a retryable notice.
        XCTAssertEqual(coordinator.launchState, .ready)
    }

    func testAFailedMigrationRetriesWithoutRelaunching() async throws {
        archive.rows = [Self.row(name: "")]
        try await startAndBootstrap()
        await awaitMigration()
        XCTAssertNotNil(coordinator.legacyMigrationFailure)

        archive.rows = [Self.row(name: "Whole Milk")]
        coordinator.retryLegacyMigration()
        await awaitMigration()

        let session = try XCTUnwrap(coordinator.session)
        XCTAssertNil(coordinator.legacyMigrationFailure)
        XCTAssertEqual(try migratedRows(in: session.persistence).map(\.name), ["Whole Milk"])
    }

    func testAnUnreadableArchiveIsReportedWithoutContent() async throws {
        archive.readFailure = LegacyInventoryArchive.ReadError(diagnosticID: "legacy.open.NSSQLite.11")

        try await startAndBootstrap()
        await awaitMigration()

        XCTAssertEqual(coordinator.legacyMigrationFailure?.diagnosticID, "legacy.open.NSSQLite.11")
        XCTAssertFalse(markers.hasMigratedLegacyInventory)
    }

    // MARK: - Notice

    func testTheNoticeSurvivesTerminationUntilItIsAcknowledged() async throws {
        try await startAndBootstrap()
        await awaitMigration()
        await waitUntil("the notice") { self.coordinator.showsMigrationNotice }

        await coordinator.shutDown()
        coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.showsMigrationNotice, "the notice was lost on relaunch")

        coordinator.acknowledgeMigrationNotice()
        XCTAssertFalse(coordinator.showsMigrationNotice)
        // Acknowledgement is its own marker: it neither depends on nor disturbs
        // the migration record.
        XCTAssertTrue(markers.hasMigratedLegacyInventory)

        await coordinator.shutDown()
        coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.showsMigrationNotice)
    }

    /// The upgrade records markers; it never clears `UserDefaults`, so the
    /// device preferences and the App Attest registration come through intact.
    func testDevicePreferencesAndAppAttestRegistrationSurviveTheUpgrade() async throws {
        defaults.set(21, forKey: "notificationHour")
        defaults.set(true, forKey: "emojiFreeMode")
        defaults.set("attest-key", forKey: "appAttest.keyID")

        try await startAndBootstrap()
        await awaitMigration()

        XCTAssertEqual(defaults.integer(forKey: "notificationHour"), 21)
        XCTAssertTrue(defaults.bool(forKey: "emojiFreeMode"))
        XCTAssertEqual(defaults.string(forKey: "appAttest.keyID"), "attest-key")
    }

    /// A store file exists on a fresh installation too — the app's own SwiftData
    /// container creates it at first launch — so "there is a file" is not
    /// evidence that a fridge moved. Nothing moved, so nothing is explained.
    func testAnArchiveWithNoActiveRowsMovesNothingAndShowsNoNotice() async throws {
        archive.rows = []

        try await startAndBootstrap()
        await awaitMigration()

        let session = try XCTUnwrap(coordinator.session)
        XCTAssertTrue(try migratedRows(in: session.persistence).isEmpty)
        XCTAssertFalse(coordinator.showsMigrationNotice)
        XCTAssertNil(coordinator.legacyMigrationFailure)
        // Settled, not pending: the archive is not re-read on every later launch.
        XCTAssertTrue(markers.hasMigratedLegacyInventory)
        await waitUntil("the upgrade to finish") { self.markers.isOnCurrentPersistenceGeneration }

        await coordinator.shutDown()
        coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.showsMigrationNotice, "an empty archive raised a notice")
    }

    func testAnInstallationWithNoArchiveAtAllMigratesNothing() async throws {
        archive.exists = false

        try await startAndBootstrap()

        let session = try XCTUnwrap(coordinator.session)
        XCTAssertTrue(try migratedRows(in: session.persistence).isEmpty)
        XCTAssertEqual(archive.readCount, 0)
        XCTAssertFalse(coordinator.showsMigrationNotice)
        XCTAssertFalse(markers.hasMigratedLegacyInventory)
        // The stack is still on the current generation: nothing is outstanding.
        XCTAssertTrue(markers.isOnCurrentPersistenceGeneration)
    }

    func testTheUpgradeFinishesOnceTheMigrationSucceeds() async throws {
        try await startAndBootstrap()
        await awaitMigration()

        await waitUntil("the upgrade to finish") { self.markers.isOnCurrentPersistenceGeneration }
    }

    /// The stack opened and the cleanup ran, but an archive is still waiting, so
    /// the installation is not finished upgrading.
    func testAFailedMigrationLeavesThePersistenceGenerationUnrecorded() async throws {
        archive.readFailure = LegacyInventoryArchive.ReadError(diagnosticID: "legacy.open.test.1")

        try await startAndBootstrap()
        await awaitMigration()

        XCTAssertFalse(markers.isOnCurrentPersistenceGeneration)
    }

    // MARK: - Seeding

    @discardableResult
    private func seedHousehold(name: String,
                               ownership: HouseholdOwnership) async throws -> UUID {
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope(), baseDirectory: baseDirectory))
        defer { controller.tearDown() }
        let id = UUID()
        let store = ownership == .owned ? controller.privateStore : controller.sharedStore
        let context = controller.newWriterContext()
        try await context.perform {
            let household = HouseholdRecord(context: context)
            household.id = id
            household.name = name
            household.initialInventoryEpochID = UUID()
            household.createdAt = Date()
            household.modifiedAt = Date()
            try StoreRouting.assign([household], to: store, in: context)
            try context.save()
        }
        return id
    }
}

/// The write itself: one transaction, exactly once, and nothing partial.
final class LegacyInventoryImportTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var householdID: UUID!

    private static let purchaseInstant = Date(timeIntervalSince1970: 1_787_097_600)

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LegacyInventoryImportTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        let scope = AccountScopeHash(digest: String(repeating: "c", count: 64))!
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
        householdID = try controller.createOwnedHousehold(named: "My Fridge").id
    }

    override func tearDown() async throws {
        controller?.tearDown()
        controller = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    private func draft(id: UUID = UUID(), name: String, quantity: Int64 = 1) -> PurchaseDraft {
        let day = InventoryDay(date: Self.purchaseInstant, calendar: .current)!
        return PurchaseDraft(itemID: id, stockChangeID: id, name: name, quantity: quantity,
                             artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: day,
                             expiryDay: day.adding(days: 5)!, expirySource: .llmEstimate,
                             explicitMetadataFields: [], occurredAt: Self.purchaseInstant)
    }

    private func storedItemCount() throws -> Int {
        let context = controller.newWriterContext()
        var result: Result<Int, Error>!
        context.performAndWait {
            result = Result { try context.count(for: FridgeItemRecord.fetchRequest()) }
        }
        return try result.get()
    }

    /// The crash-between-save-and-marker case: replaying the identical plan
    /// recognizes what it already wrote instead of writing it twice.
    func testAnIdenticalReplayWritesNothingNewAndStillSucceeds() async throws {
        let drafts = [draft(name: "Whole Milk", quantity: 2), draft(name: "Eggs", quantity: 12)]

        let first = try await controller.importLegacyInventory(drafts, into: householdID)
        let second = try await controller.importLegacyInventory(drafts, into: householdID)

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(try storedItemCount(), 2)
    }

    /// A row that is already there under a different payload is an integrity
    /// error, and it fails the whole write rather than half of it.
    func testAConflictingRowFailsTheWholeWrite() async throws {
        let milk = UUID()
        _ = try await controller.importLegacyInventory([draft(id: milk, name: "Whole Milk",
                                                              quantity: 2)],
                                                       into: householdID)

        let conflicting = [draft(id: milk, name: "Whole Milk", quantity: 3),
                           draft(name: "Eggs", quantity: 12)]
        do {
            _ = try await controller.importLegacyInventory(conflicting, into: householdID)
            XCTFail("a conflicting payload was accepted")
        } catch let error as PersistenceController.LegacyImportError {
            XCTAssertEqual(error.diagnosticID, "legacy.conflict")
        }

        XCTAssertEqual(try storedItemCount(), 1, "a row was written by a failed migration")
    }

    func testAMissingDestinationFailsWithoutWriting() async throws {
        do {
            _ = try await controller.importLegacyInventory([draft(name: "Whole Milk")],
                                                           into: UUID())
            XCTFail("a missing destination was accepted")
        } catch let error as PersistenceController.LegacyImportError {
            XCTAssertEqual(error.diagnosticID, "legacy.destination")
        }
        XCTAssertEqual(try storedItemCount(), 0)
    }

    func testAnEmptyArchiveWritesNothing() async throws {
        XCTAssertEqual(try await controller.importLegacyInventory([], into: householdID), 0)
        XCTAssertEqual(try storedItemCount(), 0)
    }
}

/// The reader, against a real archived SwiftData store.
final class LegacyInventoryArchiveTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LegacyInventoryArchiveTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("default.store", isDirectory: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Writes an archive the way the shipping build would have left one.
    private func writeArchive(_ build: (ModelContext) throws -> Void) throws {
        let configuration = ModelConfiguration(schema: Schema([FridgeItem.self]), url: storeURL,
                                               allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: FridgeItem.self, configurations: configuration)
        let context = ModelContext(container)
        try build(context)
        try context.save()
    }

    private func item(_ name: String, quantity: Int = 1) -> FridgeItem {
        FridgeItem(name: name, receiptText: "2 \(name) $4.99", artKey: ItemID.milk.rawValue,
                   quantity: quantity, expiryDate: Date().addingTimeInterval(5 * 86_400))
    }

    func testAMissingArchiveReadsNothing() throws {
        let archive = LegacyInventoryArchive(storeURL: storeURL)

        XCTAssertFalse(archive.exists)
        XCTAssertTrue(try archive.readActiveRows().isEmpty)
    }

    func testOnlyActiveRowsAreReadAndReceiptTextIsNotAmongThem() throws {
        try writeArchive { context in
            context.insert(item("Whole Milk", quantity: 2))
            let eaten = item("Old Yogurt")
            eaten.status = .eaten
            context.insert(eaten)
            let tossed = item("Wilted Kale")
            tossed.status = .tossed
            context.insert(tossed)
        }

        let archive = LegacyInventoryArchive(storeURL: storeURL)
        let rows = try archive.readActiveRows()

        XCTAssertTrue(archive.exists)
        XCTAssertEqual(rows.map(\.name), ["Whole Milk"])
        XCTAssertEqual(rows.first?.quantity, 2)
        XCTAssertEqual(rows.first?.storageRaw, StorageLocation.fridge.rawValue)
        // The row type has nowhere to put receipt text, which is the point.
        XCTAssertEqual(try LegacyInventoryPlanner.plan(rows, calendar: .current).count, 1)
    }

    /// The archive is the user's only remaining copy of eaten/tossed history, so
    /// reading it must leave every byte where it was.
    func testReadingNeitherMovesNorMutatesTheArchive() throws {
        try writeArchive { $0.insert(item("Whole Milk")) }
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)

        let archive = LegacyInventoryArchive(storeURL: storeURL)
        _ = try archive.readActiveRows()
        _ = try archive.readActiveRows()

        let after = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertTrue(archive.exists)
        XCTAssertEqual(after[.size] as? Int, attributes[.size] as? Int)
        XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
    }
}

/// Stands in for a seeded record a helper could not read back.
private struct MissingSeededRecord: Error {}
