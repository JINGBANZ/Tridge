import CoreData
import Foundation
import XCTest
@testable import Tridge

/// The Inventory commands that act on inventory a Household already has:
/// metadata edits, quantity, eat, toss, delete, Clear All, and rename.
///
/// CloudKit is disabled, so these assert on exactly what reaches the store —
/// which member a write lands on, what a retry does, and what a refused command
/// leaves behind.
final class InventoryCommandTests: XCTestCase {
    private var baseDirectory: URL!
    private var controller: PersistenceController!
    private var repository: CoreDataInventoryRepository!
    private var householdID: UUID!

    private static let today = InventoryDay(year: 2026, month: 8, day: 26)!
    private static let occurredAt = Date(timeIntervalSince1970: 1_787_097_600)
    private static let scope = AccountScopeHash(digest: String(repeating: "b", count: 64))!

    override func setUp() async throws {
        try await super.setUp()
        baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("InventoryCommandTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)
        controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: Self.scope, baseDirectory: baseDirectory))
        repository = CoreDataInventoryRepository(persistence: controller,
                                                 capabilities: FakeStoreCapabilities())
        householdID = try makeHousehold(in: controller.privateStore)
    }

    override func tearDown() async throws {
        repository = nil
        controller?.tearDown()
        controller = nil
        try? FileManager.default.removeItem(at: baseDirectory)
        try await super.tearDown()
    }

    // MARK: - Seeding

    /// Byte-ordered ids, so which physical root is canonical is decided by the
    /// test rather than by chance.
    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

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

    private func draft(_ name: String, id: UUID = UUID(), quantity: Int64 = 1,
                       art: ItemID = .milk, storage: StorageLocation = .fridge,
                       expiresInDays: Int = 5) -> PurchaseDraft {
        PurchaseDraft(itemID: id, stockChangeID: UUID(), name: name, quantity: quantity,
                      artKey: art.rawValue, storage: storage, purchaseDay: Self.today,
                      expiryDay: Self.today.adding(days: expiresInDays)!,
                      expirySource: .llmEstimate, explicitMetadataFields: [],
                      occurredAt: Self.occurredAt)
    }

    @discardableResult
    private func add(_ drafts: [PurchaseDraft],
                     to household: UUID? = nil) async throws -> HouseholdProjection {
        try await repository.addReviewedRows(
            AddReviewedRowsCommand(householdID: household ?? householdID, commandID: UUID(),
                                   rows: drafts),
            today: Self.today)
    }

    /// Two same-name roots with known byte order, so the lower id is
    /// unambiguously the canonical member of the resulting group.
    @discardableResult
    private func addLinkedPair(name: String = "Milk") async throws -> (low: UUID, high: UUID) {
        let low = Self.id(1)
        let high = Self.id(2)
        _ = try await add([draft(name, id: low), draft(name, id: high)])
        return (low, high)
    }

    // MARK: - Reading what was written

    private struct StoredEvent: Equatable {
        let id: UUID
        let itemID: UUID
        let delta: Int64
        let reason: String
        let occurredAt: Date
    }

    private func storedEvents() throws -> [StoredEvent] {
        let context = controller.newWriterContext()
        var result: Result<[StoredEvent], Error>!
        context.performAndWait {
            result = Result {
                try context.fetch(StockChangeRecord.fetchRequest()).compactMap { record in
                    guard let id = record.id, let itemID = record.item?.id,
                          let reason = record.reasonRaw, let occurredAt = record.occurredAt
                    else { return nil }
                    return StoredEvent(id: id, itemID: itemID, delta: record.delta,
                                       reason: reason, occurredAt: occurredAt)
                }
                .sorted {
                    $0.itemID == $1.itemID ? $0.reason < $1.reason
                                           : UUIDOrder.isBefore($0.itemID, $1.itemID)
                }
            }
        }
        return try result.get()
    }

    private struct StoredMetadata: Equatable {
        let artKey: String
        let storageRaw: String
        let expiryDay: Int32
        let expirySourceRaw: String
        let modifiedAt: Date
    }

    private func metadata(of itemID: UUID) throws -> StoredMetadata {
        let context = controller.newWriterContext()
        var result: Result<StoredMetadata, Error>!
        context.performAndWait {
            result = Result {
                let request = FridgeItemRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemID as NSUUID)
                guard let record = try context.fetch(request).first else { throw MissingRecord() }
                return StoredMetadata(artKey: record.artKey ?? "",
                                      storageRaw: record.storageRaw ?? "",
                                      expiryDay: record.expiryDay,
                                      expirySourceRaw: record.expirySourceRaw ?? "",
                                      modifiedAt: record.modifiedAt ?? .distantPast)
            }
        }
        return try result.get()
    }

    private struct StoredClear: Equatable {
        let id: UUID
        let epochID: UUID
        let parents: Set<UUID>
        let revision: Int64
    }

    private func storedClears() throws -> [StoredClear] {
        let context = controller.newWriterContext()
        var result: Result<[StoredClear], Error>!
        context.performAndWait {
            result = Result {
                try context.fetch(HouseholdClearRecord.fetchRequest()).compactMap { record in
                    guard let id = record.id, let epochID = record.epochID,
                          let raw = record.parentEpochIDsRaw,
                          let parents = InventoryEpochCodec.decode(raw)
                    else { return nil }
                    return StoredClear(id: id, epochID: epochID, parents: parents,
                                       revision: record.revision)
                }
                .sorted { $0.revision < $1.revision }
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

    // MARK: - Metadata edits

    func testAMetadataEditLandsOnlyOnTheLowestIDCanonicalMember() async throws {
        let pair = try await addLinkedPair()
        let before = try metadata(of: pair.high)

        let command = UpdateItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: pair.high, stockChangeID: UUID(),
                                        targetQuantity: nil, artKey: ItemID.cheese.rawValue,
                                        storage: .freezer,
                                        expiryDay: Self.today.adding(days: 40),
                                        occurredAt: Self.occurredAt)
        let projection = try await repository.updateItem(command, today: Self.today)

        // Addressed through the higher member id, applied to the canonical one.
        let canonical = try metadata(of: pair.low)
        XCTAssertEqual(canonical.artKey, ItemID.cheese.rawValue)
        XCTAssertEqual(canonical.storageRaw, StorageLocation.freezer.rawValue)
        XCTAssertEqual(canonical.expiryDay, Self.today.adding(days: 40)!.ordinal)
        XCTAssertEqual(canonical.expirySourceRaw, ExpirySource.userSet.rawValue,
                       "a date the user chose is never a model guess again")
        XCTAssertEqual(canonical.modifiedAt, Self.occurredAt)
        XCTAssertEqual(try metadata(of: pair.high), before,
                       "the non-canonical member is untouched")
        XCTAssertEqual(projection.items.first?.artKey, ItemID.cheese.rawValue)
    }

    func testAStockOnlyCommandLeavesModifiedAtAlone() async throws {
        let pair = try await addLinkedPair()
        let before = try metadata(of: pair.low)

        let command = ConsumeItemCommand(householdID: householdID, commandID: UUID(),
                                         itemID: pair.low, stockChangeID: UUID(),
                                         reason: .eaten, occurredAt: Self.occurredAt.addingTimeInterval(60))
        _ = try await repository.consumeItem(XCTUnwrap(command), today: Self.today)

        XCTAssertEqual(try metadata(of: pair.low).modifiedAt, before.modifiedAt,
                       "eating is not an edit")
    }

    func testAnUntouchedDraftWritesNothing() async throws {
        let pair = try await addLinkedPair()
        let eventsBefore = try storedEvents()

        let command = UpdateItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: pair.low, stockChangeID: UUID(),
                                        targetQuantity: 2, artKey: ItemID.milk.rawValue,
                                        storage: .fridge,
                                        expiryDay: Self.today.adding(days: 5),
                                        occurredAt: Self.occurredAt)
        _ = try await repository.updateItem(command, today: Self.today)

        XCTAssertEqual(try storedEvents(), eventsBefore,
                       "a draft that matches the projection commits no operation")
    }

    // MARK: - Quantity

    func testQuantityCommitsTheDifferenceFromTheVisibleProjection() async throws {
        let pair = try await addLinkedPair()   // two roots of one unit each

        let stockChangeID = UUID()
        let command = UpdateItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: pair.low, stockChangeID: stockChangeID,
                                        targetQuantity: 5, artKey: nil, storage: nil,
                                        expiryDay: nil, occurredAt: Self.occurredAt)
        let projection = try await repository.updateItem(command, today: Self.today)

        let adjustment = try XCTUnwrap(storedEvents().first { $0.id == stockChangeID })
        XCTAssertEqual(adjustment.delta, 3, "5 wanted, 2 visible")
        XCTAssertEqual(adjustment.reason, StockReason.adjusted.rawValue)
        XCTAssertEqual(adjustment.itemID, pair.low, "appended to the lowest-id member")
        XCTAssertEqual(projection.items.first?.quantity, 5)
    }

    func testAnIdenticalQuantityRetryAppliesOnce() async throws {
        let pair = try await addLinkedPair()
        let command = UpdateItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: pair.low, stockChangeID: UUID(),
                                        targetQuantity: 5, artKey: nil, storage: nil,
                                        expiryDay: nil, occurredAt: Self.occurredAt)

        _ = try await repository.updateItem(command, today: Self.today)
        let projection = try await repository.updateItem(command, today: Self.today)

        XCTAssertEqual(projection.items.first?.quantity, 5,
                       "the replay must not adjust a second time")
        XCTAssertEqual(try storedEvents().filter { $0.reason == StockReason.adjusted.rawValue }
            .count, 1)
    }

    // MARK: - Eat and toss

    func testEatAndTossAppendMinusOneToTheLowestIDMember() async throws {
        let pair = try await addLinkedPair()

        let eat = try XCTUnwrap(ConsumeItemCommand(householdID: householdID, commandID: UUID(),
                                                   itemID: pair.high, stockChangeID: UUID(),
                                                   reason: .eaten, occurredAt: Self.occurredAt))
        let afterEat = try await repository.consumeItem(eat, today: Self.today)
        XCTAssertEqual(afterEat.items.first?.quantity, 1)

        let toss = try XCTUnwrap(ConsumeItemCommand(householdID: householdID, commandID: UUID(),
                                                    itemID: pair.high, stockChangeID: UUID(),
                                                    reason: .tossed, occurredAt: Self.occurredAt))
        let afterToss = try await repository.consumeItem(toss, today: Self.today)
        XCTAssertTrue(afterToss.items.isEmpty, "zero hides the projection")

        let consumed = try storedEvents().filter { $0.delta == -1 }
        XCTAssertEqual(Set(consumed.map(\.itemID)), [pair.low],
                       "both landed on the canonical member, whichever id was addressed")
        XCTAssertEqual(Set(consumed.map(\.reason)),
                       [StockReason.eaten.rawValue, StockReason.tossed.rawValue])
    }

    func testAnIdenticalConsumeRetryAppliesOnce() async throws {
        let pair = try await addLinkedPair()
        let command = try XCTUnwrap(ConsumeItemCommand(householdID: householdID,
                                                       commandID: UUID(), itemID: pair.low,
                                                       stockChangeID: UUID(), reason: .eaten,
                                                       occurredAt: Self.occurredAt))

        _ = try await repository.consumeItem(command, today: Self.today)
        let projection = try await repository.consumeItem(command, today: Self.today)

        XCTAssertEqual(projection.items.first?.quantity, 1)
        XCTAssertEqual(try storedEvents().filter { $0.delta == -1 }.count, 1)
    }

    func testAConflictingPayloadUnderOneCommandIDIsRefused() async throws {
        let pair = try await addLinkedPair()
        let stockChangeID = UUID()
        let first = try XCTUnwrap(ConsumeItemCommand(householdID: householdID, commandID: UUID(),
                                                     itemID: pair.low,
                                                     stockChangeID: stockChangeID, reason: .eaten,
                                                     occurredAt: Self.occurredAt))
        _ = try await repository.consumeItem(first, today: Self.today)

        // Same command id, different reason: neither copy can be trusted.
        let conflicting = try XCTUnwrap(ConsumeItemCommand(householdID: householdID,
                                                           commandID: UUID(), itemID: pair.low,
                                                           stockChangeID: stockChangeID,
                                                           reason: .tossed,
                                                           occurredAt: Self.occurredAt))
        await assertThrows(.conflictingRetry(stockChangeID)) {
            _ = try await self.repository.consumeItem(conflicting, today: Self.today)
        }
    }

    // MARK: - Delete

    func testDeleteFansOneTerminalMarkerAcrossEveryLinkedMember() async throws {
        let pair = try await addLinkedPair()
        let stockChangeID = UUID()

        let projection = try await repository.deleteItem(
            DeleteItemCommand(householdID: householdID, commandID: UUID(), itemID: pair.high,
                              stockChangeID: stockChangeID, occurredAt: Self.occurredAt),
            today: Self.today)

        XCTAssertTrue(projection.items.isEmpty)
        let markers = try storedEvents().filter { $0.id == stockChangeID }
        XCTAssertEqual(Set(markers.map(\.itemID)), [pair.low, pair.high],
                       "every currently linked member carries the marker")
        XCTAssertTrue(markers.allSatisfy {
            $0.delta == 0 && $0.reason == StockReason.deleted.rawValue
        })
    }

    func testADeleteRetryFillsOnlyTheMissingMarkers() async throws {
        let pair = try await addLinkedPair()
        let stockChangeID = UUID()
        let command = DeleteItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: pair.low, stockChangeID: stockChangeID,
                                        occurredAt: Self.occurredAt)
        _ = try await repository.deleteItem(command, today: Self.today)

        // Finding the id on some members is not completion; a replay has to be
        // able to run again and still write nothing new.
        _ = try await repository.deleteItem(command, today: Self.today)

        XCTAssertEqual(try storedEvents().filter { $0.id == stockChangeID }.count, 2)
    }

    func testDeletingAnItemThatWasNeverInThisHouseholdIsRefused() async throws {
        _ = try await addLinkedPair()

        await assertThrows(.itemUnavailable) {
            _ = try await self.repository.deleteItem(
                DeleteItemCommand(householdID: self.householdID, commandID: UUID(),
                                  itemID: UUID(), stockChangeID: UUID(),
                                  occurredAt: Self.occurredAt),
                today: Self.today)
        }
    }

    // MARK: - Stale drafts

    func testAStaleDraftForADeletedGroupIsRefusedWithoutWriting() async throws {
        let pair = try await addLinkedPair()
        _ = try await repository.deleteItem(
            DeleteItemCommand(householdID: householdID, commandID: UUID(), itemID: pair.low,
                              stockChangeID: UUID(), occurredAt: Self.occurredAt),
            today: Self.today)
        let eventsBefore = try storedEvents()

        await assertThrows(.itemUnavailable) {
            _ = try await self.repository.updateItem(
                UpdateItemCommand(householdID: self.householdID, commandID: UUID(),
                                  itemID: pair.low, stockChangeID: UUID(), targetQuantity: 4,
                                  artKey: nil, storage: nil, expiryDay: nil,
                                  occurredAt: Self.occurredAt),
                today: Self.today)
        }
        XCTAssertEqual(try storedEvents(), eventsBefore)
    }

    // MARK: - Clear All

    func testClearAllWritesOneFullFrontierBarrierAndNoItemEvent() async throws {
        _ = try await addLinkedPair()
        let initial = try initialEpochID(of: householdID)
        let eventsBefore = try storedEvents()

        let epochID = UUID()
        let projection = try await repository.clearActiveHousehold(
            ClearHouseholdCommand(householdID: householdID, commandID: UUID(),
                                  clearRecordID: UUID(), epochID: epochID,
                                  occurredAt: Self.occurredAt),
            today: Self.today)

        XCTAssertTrue(projection.items.isEmpty, "every pre-clear root is superseded")
        XCTAssertEqual(try storedEvents(), eventsBefore,
                       "Clear All appends no item-level stock event")
        let clears = try storedClears()
        XCTAssertEqual(clears.count, 1)
        XCTAssertEqual(clears[0].epochID, epochID)
        XCTAssertEqual(clears[0].parents, [initial], "the complete visible frontier")
        XCTAssertEqual(clears[0].revision, 1)
    }

    func testAClearRetryReplaysTheRecordItAlreadyWrote() async throws {
        _ = try await addLinkedPair()
        let command = ClearHouseholdCommand(householdID: householdID, commandID: UUID(),
                                            clearRecordID: UUID(), epochID: UUID(),
                                            occurredAt: Self.occurredAt)

        _ = try await repository.clearActiveHousehold(command, today: Self.today)
        _ = try await repository.clearActiveHousehold(command, today: Self.today)

        // A rebuilt record would carry the same id with the *new* frontier as
        // its parents, and two conflicting copies of one clear drop both.
        XCTAssertEqual(try storedClears().count, 1)
    }

    func testAPurchaseAfterAClearIsCurrentAgain() async throws {
        _ = try await addLinkedPair()
        _ = try await repository.clearActiveHousehold(
            ClearHouseholdCommand(householdID: householdID, commandID: UUID(),
                                  clearRecordID: UUID(), epochID: UUID(),
                                  occurredAt: Self.occurredAt),
            today: Self.today)

        let projection = try await add([draft("Eggs", quantity: 6)])
        XCTAssertEqual(projection.items.map(\.name), ["Eggs"])
    }

    // MARK: - Rename

    func testRenamingAnOwnedHouseholdSavesTheNewName() async throws {
        let snapshot = try await repository.renameOwnedHousehold(
            RenameHouseholdCommand(householdID: householdID, commandID: UUID(),
                                   name: "  Beach House  "))

        XCTAssertEqual(snapshot.name, "Beach House")
        XCTAssertEqual(snapshot.ownership, .owned)
    }

    func testRenamingAReceivedHouseholdIsRefused() async throws {
        let received = try makeHousehold(in: controller.sharedStore, name: "Their Fridge")

        await assertThrows(.householdNotOwned) {
            _ = try await self.repository.renameOwnedHousehold(
                RenameHouseholdCommand(householdID: received, commandID: UUID(), name: "Mine"))
        }
    }

    // MARK: - Capability denial

    func testCapabilityDenialWritesNothing() async throws {
        let pair = try await addLinkedPair()
        let eventsBefore = try storedEvents()
        let metadataBefore = try metadata(of: pair.low)
        let denied = CoreDataInventoryRepository(
            persistence: controller, capabilities: FakeStoreCapabilities(canModify: false))

        for command in [
            { try await denied.updateItem(
                UpdateItemCommand(householdID: self.householdID, commandID: UUID(),
                                  itemID: pair.low, stockChangeID: UUID(), targetQuantity: 9,
                                  artKey: ItemID.cheese.rawValue, storage: nil, expiryDay: nil,
                                  occurredAt: Self.occurredAt),
                today: Self.today) },
            { try await denied.deleteItem(
                DeleteItemCommand(householdID: self.householdID, commandID: UUID(),
                                  itemID: pair.low, stockChangeID: UUID(),
                                  occurredAt: Self.occurredAt),
                today: Self.today) },
            { try await denied.clearActiveHousehold(
                ClearHouseholdCommand(householdID: self.householdID, commandID: UUID(),
                                      clearRecordID: UUID(), epochID: UUID(),
                                      occurredAt: Self.occurredAt),
                today: Self.today) },
        ] as [() async throws -> HouseholdProjection] {
            await assertThrows(.permissionDenied) { _ = try await command() }
        }

        XCTAssertEqual(try storedEvents(), eventsBefore)
        XCTAssertEqual(try metadata(of: pair.low), metadataBefore)
        XCTAssertTrue(try storedClears().isEmpty)
    }

    // MARK: - Helpers

    private func assertThrows(_ expected: InventoryRepositoryError,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as InventoryRepositoryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private struct MissingRecord: Error {}
