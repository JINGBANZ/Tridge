import XCTest
@testable import FridgeCore

final class ItemGroupReducerTests: XCTestCase {
    private let epoch = UUID()
    private let today = InventoryDay(year: 2026, month: 8, day: 18)!

    private var frontier: InventoryEpochReduction {
        InventoryEpochReducer.reduce(initialEpochID: epoch, clears: [])
    }

    private func itemID(_ seed: UInt8) -> UUID {
        UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    private func root(_ seed: UInt8, name: String = "Milk", context: Set<UUID>? = nil,
                      art: ItemID = .milk, storage: StorageLocation = .fridge,
                      expiresInDays: Int = 5) -> PhysicalItemSnapshot {
        PhysicalItemSnapshot(id: itemID(seed), name: name, inventoryContext: context ?? [epoch],
                             artKey: art.rawValue, storage: storage,
                             purchaseDay: today, expiryDay: today.adding(days: expiresInDays)!,
                             expirySource: .llmEstimate,
                             createdAt: Date(timeIntervalSince1970: 0),
                             modifiedAt: Date(timeIntervalSince1970: 0))
    }

    private func acquired(_ seed: UInt8, _ delta: Int64) -> StockEvent {
        StockEvent(id: itemID(seed), delta: delta, reason: .acquired,
                   occurredAt: Date(timeIntervalSince1970: 0))
    }

    private func project(_ items: [PhysicalItemSnapshot],
                         claims: [ItemMergeClaimRecord] = [],
                         events: [UUID: [StockEvent]],
                         epochs: InventoryEpochReduction? = nil) -> ItemGroupProjection {
        ItemGroupReducer.project(items: items, claims: claims, events: events,
                                 epochs: epochs ?? frontier, today: today)
    }

    func testASinglePurchaseRootProjectsAsOneItem() {
        let milk = root(1)
        let projection = project([milk], events: [milk.id: [acquired(10, 2)]])

        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.id, milk.id)
        XCTAssertEqual(projection.items.first?.memberIDs, [milk.id])
        XCTAssertEqual(projection.items.first?.quantity, 2)
        XCTAssertEqual(projection.items.first?.name, "Milk")
        XCTAssertTrue(projection.inferredClaims.isEmpty)
    }
}

extension ItemGroupReducerTests {
    private func record(_ claim: ItemMergeClaim, id: UUID = UUID()) -> ItemMergeClaimRecord {
        ItemMergeClaimRecord(id: id, claim: claim)
    }

    func testClaimEndpointsAreSortedAndSelfClaimsRejected() throws {
        let claim = ItemMergeClaim(itemID(9), itemID(2))
        XCTAssertEqual(claim?.leftItemID, itemID(2))
        XCTAssertEqual(claim?.rightItemID, itemID(9))
        XCTAssertNil(ItemMergeClaim(itemID(2), itemID(2)))

        XCTAssertThrowsError(try ItemMergeClaimRecord(id: UUID(), leftItemID: itemID(2),
                                                      rightItemID: itemID(2)))
        // Stored out of byte order is corrupt: peers must write one form.
        XCTAssertThrowsError(try ItemMergeClaimRecord(id: UUID(), leftItemID: itemID(9),
                                                      rightItemID: itemID(2)))
        XCTAssertNoThrow(try ItemMergeClaimRecord(id: UUID(), leftItemID: itemID(2),
                                                  rightItemID: itemID(9)))
    }

    func testClaimsProduceTheSameComponentsInAnyOrderAndSurviveDuplicates() {
        let items = [root(1), root(2), root(3)]
        let events = [itemID(1): [acquired(11, 1)], itemID(2): [acquired(12, 1)],
                      itemID(3): [acquired(13, 1)]]
        let claims = [record(ItemMergeClaim(itemID(1), itemID(2))!),
                      record(ItemMergeClaim(itemID(2), itemID(3))!)]

        let forward = project(items, claims: claims, events: events)
        let reversed = project(items.reversed(), claims: claims.reversed(), events: events)
        // Duplicate claims are expected when two peers reconcile concurrently.
        let duplicated = project(items, claims: claims + claims.map { record($0.claim) },
                                 events: events)

        XCTAssertEqual(forward.items.count, 1)
        XCTAssertEqual(forward.items.first?.quantity, 3)
        XCTAssertEqual(forward.items.first?.memberIDs, [itemID(1), itemID(2), itemID(3)])
        XCTAssertEqual(forward.items, reversed.items)
        XCTAssertEqual(forward.items, duplicated.items)
    }

    func testLowestMemberIdSuppliesIdentityAndMetadata() {
        // The higher-id root carries different metadata; the canonical member wins.
        let low = root(2, art: .milk, storage: .fridge)
        let high = root(7, art: .cheese, storage: .freezer)
        let projection = project([high, low],
                                 claims: [record(ItemMergeClaim(low.id, high.id)!)],
                                 events: [low.id: [acquired(11, 1)], high.id: [acquired(12, 4)]])

        XCTAssertEqual(projection.items.first?.id, low.id)
        XCTAssertEqual(projection.items.first?.artKey, ItemID.milk.rawValue)
        XCTAssertEqual(projection.items.first?.storage, .fridge)
        XCTAssertEqual(projection.items.first?.quantity, 5)
    }

    func testALateOperationOnAnyMemberChangesTheAggregate() {
        let first = root(1), second = root(2)
        let claims = [record(ItemMergeClaim(first.id, second.id)!)]
        var events = [first.id: [acquired(11, 1)], second.id: [acquired(12, 1)]]
        XCTAssertEqual(project([first, second], claims: claims, events: events).items.first?.quantity, 2)

        // An offline member's eat finally imports, written to the original root.
        events[second.id]?.append(StockEvent(id: itemID(20), delta: -1, reason: .eaten,
                                             occurredAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(project([first, second], claims: claims, events: events).items.first?.quantity, 1)
    }

    func testDeleteFansOutAcrossMembersButCountsOnce() {
        // Delete appends one stable id/payload to every linked member.
        let first = root(1), second = root(2)
        let marker = StockEvent(id: itemID(30), delta: 0, reason: .deleted,
                                occurredAt: Date(timeIntervalSince1970: 5))
        let projection = project([first, second],
                                 claims: [record(ItemMergeClaim(first.id, second.id)!)],
                                 events: [first.id: [acquired(11, 2), marker],
                                          second.id: [acquired(12, 3), marker]])
        XCTAssertTrue(projection.items.isEmpty)
        XCTAssertTrue(projection.stockIssues.isEmpty, "the repeated marker is not a conflict")
    }

    func testConcurrentSameNameRootsConvergeWithoutLosingEitherHistory() {
        // Both members added Milk offline; neither could see the other's root.
        let mine = root(1), theirs = root(4)
        let projection = project([mine, theirs],
                                 events: [mine.id: [acquired(11, 1)], theirs.id: [acquired(12, 1)]])

        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.quantity, 2)
        XCTAssertEqual(projection.items.first?.memberIDs, [mine.id, theirs.id])
        XCTAssertEqual(projection.inferredClaims, [ItemMergeClaim(mine.id, theirs.id)!],
                       "the reconciler is told exactly which claim to persist")
    }

    func testThreeConcurrentRootsLinkAsAStarFromTheLowestId() {
        let items = [root(1), root(2), root(3)]
        let projection = project(items, events: [itemID(1): [acquired(11, 1)],
                                                 itemID(2): [acquired(12, 1)],
                                                 itemID(3): [acquired(13, 1)]])
        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(Set(projection.inferredClaims),
                       [ItemMergeClaim(itemID(1), itemID(2))!,
                        ItemMergeClaim(itemID(1), itemID(3))!])
    }

    func testDifferentNamesNeverConverge() {
        let milk = root(1, name: "Milk"), oat = root(2, name: "Oat Milk")
        let projection = project([milk, oat], events: [milk.id: [acquired(11, 1)],
                                                       oat.id: [acquired(12, 1)]])
        XCTAssertEqual(projection.items.count, 2)
        XCTAssertTrue(projection.inferredClaims.isEmpty)
    }

    func testExpiredZeroAndDeletedGroupsAreNeverAutoLinked() {
        let active = root(1)
        let expired = root(2, expiresInDays: -1)
        let depleted = root(3)
        let deleted = root(4)
        let projection = project([active, expired, depleted, deleted],
                                 events: [active.id: [acquired(11, 1)],
                                          expired.id: [acquired(12, 1)],
                                          depleted.id: [acquired(13, 1),
                                                        StockEvent(id: itemID(23), delta: -1,
                                                                   reason: .eaten,
                                                                   occurredAt: Date(timeIntervalSince1970: 1))],
                                          deleted.id: [acquired(14, 1),
                                                       StockEvent(id: itemID(24), delta: 0,
                                                                  reason: .deleted,
                                                                  occurredAt: Date(timeIntervalSince1970: 1))]])

        XCTAssertTrue(projection.inferredClaims.isEmpty)
        // The expired batch still shows — it just cannot absorb the new one.
        XCTAssertEqual(projection.items.map(\.id), [expired.id, active.id])
    }

    func testAClaimStaysPermanentAfterTheGroupExpires() {
        // Time or quantity changes never split an already-linked history.
        let first = root(1, expiresInDays: -3), second = root(2, expiresInDays: -3)
        let projection = project([first, second],
                                 claims: [record(ItemMergeClaim(first.id, second.id)!)],
                                 events: [first.id: [acquired(11, 1)], second.id: [acquired(12, 1)]])
        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.quantity, 2)
    }

    func testARevivedZeroGroupBecomesEligibleAgain() {
        let active = root(1)
        let revived = root(2)
        let projection = project([active, revived],
                                 events: [active.id: [acquired(11, 1)],
                                          revived.id: [acquired(12, 1),
                                                       StockEvent(id: itemID(22), delta: -1,
                                                                  reason: .eaten,
                                                                  occurredAt: Date(timeIntervalSince1970: 1)),
                                                       StockEvent(id: itemID(23), delta: 2,
                                                                  reason: .acquired,
                                                                  occurredAt: Date(timeIntervalSince1970: 2))]])
        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.quantity, 3)
    }

    func testAClaimJoiningDifferentNamesIsCorruptAndNotApplied() {
        let milk = root(1, name: "Milk"), cheese = root(2, name: "Cheese")
        let claim = record(ItemMergeClaim(milk.id, cheese.id)!)
        let projection = project([milk, cheese], claims: [claim],
                                 events: [milk.id: [acquired(11, 1)], cheese.id: [acquired(12, 1)]])

        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(projection.issues,
                       [RecordIntegrityIssue(entity: .itemMerge, id: claim.id,
                                             category: .invalidRelationship)])
    }

    func testAClaimWhoseEndpointHasNotImportedYetIsNotCorrupt() {
        let milk = root(1)
        let projection = project([milk], claims: [record(ItemMergeClaim(milk.id, itemID(9))!)],
                                 events: [milk.id: [acquired(11, 1)]])
        XCTAssertEqual(projection.items.count, 1)
        XCTAssertTrue(projection.issues.isEmpty, "waiting for an import is not corruption")
    }

    func testSupersededRootsAreExcludedFromTheProjection() {
        let cleared = UUID()
        let epochs = InventoryEpochReducer.reduce(
            initialEpochID: epoch,
            clears: [HouseholdClearRecord(id: UUID(), epochID: cleared, parentEpochIDs: [epoch],
                                          revision: 1, occurredAt: Date(timeIntervalSince1970: 1))])
        let old = root(1, context: [epoch])
        let new = root(2, context: [cleared])
        let projection = project([old, new], events: [old.id: [acquired(11, 5)],
                                                      new.id: [acquired(12, 1)]],
                                 epochs: epochs)

        XCTAssertEqual(projection.items.map(\.id), [new.id])
        XCTAssertTrue(projection.inferredClaims.isEmpty, "a superseded root cannot be linked")
    }

    func testRootsAddedAfterEitherConcurrentClearStillConverge() {
        // Two offline clears, then each member buys Milk on its own branch.
        let mine = UUID(), theirs = UUID()
        let epochs = InventoryEpochReducer.reduce(
            initialEpochID: epoch,
            clears: [HouseholdClearRecord(id: UUID(), epochID: mine, parentEpochIDs: [epoch],
                                          revision: 1, occurredAt: Date(timeIntervalSince1970: 1)),
                     HouseholdClearRecord(id: UUID(), epochID: theirs, parentEpochIDs: [epoch],
                                          revision: 1, occurredAt: Date(timeIntervalSince1970: 2))])
        let onMine = root(1, context: [mine])
        let onTheirs = root(2, context: [theirs])
        let projection = project([onMine, onTheirs], events: [onMine.id: [acquired(11, 1)],
                                                              onTheirs.id: [acquired(12, 1)]],
                                 epochs: epochs)

        XCTAssertEqual(projection.items.count, 1, "different contexts still converge by name")
        XCTAssertEqual(projection.items.first?.quantity, 2)
    }

    func testDiagnosticOrderDoesNotDependOnGroupIterationOrder() {
        // Groups reduce in dictionary order; the reported sequence must not.
        let first = root(1, name: "Rice"), second = root(2, name: "Oats")
        let events = [first.id: [acquired(11, .max), acquired(12, 1)],
                      second.id: [acquired(13, 4), acquired(14, -1)]]
        let forward = project([first, second], events: events)
        let reversed = project([second, first], events: events)

        XCTAssertFalse(forward.stockIssues.isEmpty)
        XCTAssertEqual(forward.stockIssues, reversed.stockIssues)
        XCTAssertEqual(forward.stockIssues, project([first, second], events: events).stockIssues)
    }

    func testACorruptStockHistoryWithholdsOnlyThatItem() {
        let good = root(1), overflowing = root(2, name: "Rice")
        let projection = project([good, overflowing],
                                 events: [good.id: [acquired(11, 1)],
                                          overflowing.id: [acquired(12, .max), acquired(13, 1)]])
        XCTAssertEqual(projection.items.map(\.id), [good.id])
        XCTAssertTrue(projection.stockIssues.contains(.quantityOverflow))
    }
}

/// End-to-end checks over the pure contracts: the behaviors the acceptance
/// criteria describe in product terms rather than per-reducer terms.
extension ItemGroupReducerTests {
    func testClearAllHidesPriorInventoryWithoutWritingAnyItemLevelEvent() {
        // ADR 0009: the household frontier is the only record a clear writes.
        let existing = root(1)
        let history = [acquired(11, 3)]
        let before = project([existing], events: [existing.id: history])
        XCTAssertEqual(before.items.count, 1)

        let command = ClearHouseholdCommand(householdID: UUID(), commandID: UUID(),
                                            clearRecordID: UUID(), epochID: UUID(),
                                            occurredAt: Date(timeIntervalSince1970: 1))
        let record = command.clearRecord(from: frontier)!
        let cleared = InventoryEpochReducer.reduce(initialEpochID: epoch, clears: [record])

        // The item disappears, and its stock history is untouched.
        let after = project([existing], events: [existing.id: history], epochs: cleared)
        XCTAssertTrue(after.items.isEmpty)
        XCTAssertEqual(StockReducer.reduce(history).quantity, 3)

        // Groceries bought after the clear are on the new frontier and remain.
        let fresh = root(2, name: "Eggs", context: [command.epochID])
        let restocked = project([existing, fresh], events: [existing.id: history,
                                                            fresh.id: [acquired(12, 6)]],
                                epochs: cleared)
        XCTAssertEqual(restocked.items.map(\.id), [fresh.id])
    }

    func testAPurchaseAfterAZeroGroupStartsAFreshRootInsteadOfPayingDownTheOldOne() {
        // ADR 0010: a locally zero group is not a merge target.
        let depleted = root(1)
        let events = [depleted.id: [acquired(11, 1),
                                    StockEvent(id: itemID(21), delta: -1, reason: .eaten,
                                               occurredAt: Date(timeIntervalSince1970: 1))]]
        let projection = project([depleted], events: events)
        XCTAssertTrue(projection.items.isEmpty)

        let repurchase = PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: "Milk",
                                       quantity: 2, artKey: ItemID.milk.rawValue, storage: .fridge,
                                       purchaseDay: today, expiryDay: today.adding(days: 6)!,
                                       expirySource: .llmEstimate, explicitMetadataFields: [])
        let match = PurchasePlanner.match(name: repurchase.name, in: projection.items, today: today)
        XCTAssertNil(match, "a zero group cannot absorb the new purchase")

        let plan = PurchasePlanner.plan(for: repurchase, matching: match)
        XCTAssertEqual(plan.rootMetadata.expiryDay, repurchase.expiryDay)
        XCTAssertEqual(repurchase.acquisition.reason, .acquired)
        XCTAssertEqual(repurchase.acquisition.delta, 2)
        XCTAssertEqual(repurchase.acquisition.id, repurchase.stockChangeID)

        // The fresh root's own history is all that shows; the old one stays put.
        let newRoot = root(2, name: "Milk")
        let after = project([depleted, newRoot],
                            events: events.merging([newRoot.id: [repurchase.acquisition]]) { a, _ in a })
        XCTAssertEqual(after.items.map(\.id), [newRoot.id])
        XCTAssertEqual(after.items.first?.quantity, 2)
    }
}
