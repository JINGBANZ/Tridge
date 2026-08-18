import XCTest
@testable import FridgeCore

final class InventoryQuantityTests: XCTestCase {
    func testAcceptsAnyPositiveWholeNumber() throws {
        XCTAssertEqual(try InventoryQuantity.parse("1"), 1)
        XCTAssertEqual(try InventoryQuantity.parse(" 42 "), 42)
        // ADR 0004: no 99-unit product cap.
        XCTAssertEqual(try InventoryQuantity.parse("100"), 100)
        XCTAssertEqual(try InventoryQuantity.parse("9223372036854775807"), .max)
    }

    func testRejectsInsteadOfClamping() {
        func assertRejects(_ text: String, _ expected: InventoryCommandError) {
            XCTAssertThrowsError(try InventoryQuantity.parse(text)) { error in
                XCTAssertEqual(error as? InventoryCommandError, expected, text)
            }
        }
        assertRejects("0", .quantityNotPositive)
        assertRejects("-3", .quantityNotPositive)
        assertRejects("", .quantityNotANumber)
        assertRejects("   ", .quantityNotANumber)
        assertRejects("two", .quantityNotANumber)
        assertRejects("1.5", .quantityNotANumber)
        assertRejects("1e3", .quantityNotANumber)
        assertRejects("+5", .quantityNotANumber)
        // Beyond Int64: rejected, never wrapped or clamped.
        assertRejects("9223372036854775808", .quantityOutOfRange)
    }
}

final class InventoryCommandsTests: XCTestCase {
    private let household = UUID()
    private let today = InventoryDay(year: 2026, month: 8, day: 18)!

    private func draft(name: String = "Milk", quantity: Int64 = 1,
                       explicit: Set<ExplicitMetadataField> = []) -> PurchaseDraft {
        PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: name, quantity: quantity,
                      artKey: ItemID.milk.rawValue, storage: .fridge, purchaseDay: today,
                      expiryDay: today.adding(days: 7)!, expirySource: .llmEstimate,
                      explicitMetadataFields: explicit)
    }

    func testManualAddValidates() throws {
        XCTAssertNoThrow(try AddManualItemCommand(householdID: household, commandID: UUID(),
                                                  draft: draft()).validate())
        XCTAssertThrowsError(try AddManualItemCommand(householdID: household, commandID: UUID(),
                                                      draft: draft(name: "   ")).validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .emptyItemName)
        }
        XCTAssertThrowsError(try AddManualItemCommand(householdID: household, commandID: UUID(),
                                                      draft: draft(quantity: 0)).validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .quantityNotPositive)
        }
    }

    func testReviewedRowsNeedDistinctPreallocatedIds() throws {
        let first = draft(name: "Milk"), second = draft(name: "Eggs")
        XCTAssertNoThrow(try AddReviewedRowsCommand(householdID: household, commandID: UUID(),
                                                    rows: [first, second]).validate())
        XCTAssertThrowsError(try AddReviewedRowsCommand(householdID: household, commandID: UUID(),
                                                        rows: []).validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .noRows)
        }
        XCTAssertThrowsError(try AddReviewedRowsCommand(householdID: household, commandID: UUID(),
                                                        rows: [first, first]).validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .duplicatePreallocatedID)
        }
    }

    func testAMetadataOnlyUpdateNeedsAtLeastOneChange() throws {
        let empty = UpdateItemCommand(householdID: household, commandID: UUID(), itemID: UUID(),
                                      stockChangeID: UUID(), targetQuantity: nil, artKey: nil,
                                      storage: nil, expiryDay: nil)
        XCTAssertThrowsError(try empty.validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .noChanges)
        }
        XCTAssertFalse(empty.needsStockEvent)

        let quantity = UpdateItemCommand(householdID: household, commandID: UUID(), itemID: UUID(),
                                         stockChangeID: UUID(), targetQuantity: 4, artKey: nil,
                                         storage: nil, expiryDay: nil)
        XCTAssertNoThrow(try quantity.validate())
        XCTAssertTrue(quantity.needsStockEvent)

        let zeroed = UpdateItemCommand(householdID: household, commandID: UUID(), itemID: UUID(),
                                       stockChangeID: UUID(), targetQuantity: 0, artKey: nil,
                                       storage: nil, expiryDay: nil)
        XCTAssertThrowsError(try zeroed.validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .quantityNotPositive)
        }
    }

    func testQuantityFieldCommitsTheDifferenceFromWhatTheEditorCouldSee() {
        let update = UpdateItemCommand(householdID: household, commandID: UUID(), itemID: UUID(),
                                       stockChangeID: UUID(), targetQuantity: 5, artKey: nil,
                                       storage: nil, expiryDay: nil)
        XCTAssertEqual(update.adjustment(fromLocalProjection: 2)?.delta, 3)
        XCTAssertEqual(update.adjustment(fromLocalProjection: 9)?.delta, -4)
        XCTAssertEqual(update.adjustment(fromLocalProjection: 9)?.reason, .adjusted)
        XCTAssertNil(update.adjustment(fromLocalProjection: 5), "no change commits no operation")
    }

    func testEventPayloadsAreStableSoARetryIsRecognisedAsTheSameOperation() {
        // The repository reads a repeated command id with a different payload as
        // an integrity error, so the instant is fixed when the command is built.
        let purchase = draft()
        XCTAssertEqual(purchase.acquisition, purchase.acquisition)

        let consume = ConsumeItemCommand(householdID: household, commandID: UUID(),
                                         itemID: UUID(), stockChangeID: UUID(), reason: .eaten)!
        XCTAssertEqual(consume.event, consume.event)

        let delete = DeleteItemCommand(householdID: household, commandID: UUID(),
                                       itemID: UUID(), stockChangeID: UUID())
        XCTAssertEqual(delete.marker, delete.marker)

        let update = UpdateItemCommand(householdID: household, commandID: UUID(), itemID: UUID(),
                                       stockChangeID: UUID(), targetQuantity: 4, artKey: nil,
                                       storage: nil, expiryDay: nil)
        XCTAssertEqual(update.adjustment(fromLocalProjection: 1),
                       update.adjustment(fromLocalProjection: 1))

        // Replaying the retained command reduces exactly once.
        XCTAssertEqual(StockReducer.reduce([purchase.acquisition, purchase.acquisition]).quantity,
                       purchase.quantity)
    }

    func testOnlyEatAndTossAreConsumeReasons() {
        for reason in StockReason.allCases {
            let command = ConsumeItemCommand(householdID: household, commandID: UUID(),
                                             itemID: UUID(), stockChangeID: UUID(), reason: reason)
            XCTAssertEqual(command != nil, reason == .eaten || reason == .tossed, reason.rawValue)
            if let command { XCTAssertEqual(command.event.delta, -1) }
        }
    }

    func testDeleteMarkerIsTheTerminalZeroDeltaPayloadFannedAcrossMembers() {
        let delete = DeleteItemCommand(householdID: household, commandID: UUID(),
                                       itemID: UUID(), stockChangeID: UUID())
        XCTAssertEqual(delete.marker.reason, .deleted)
        XCTAssertEqual(delete.marker.delta, 0)
        XCTAssertEqual(delete.marker.id, delete.stockChangeID)
    }

    func testRenameRequiresANonEmptyHouseholdName() {
        XCTAssertThrowsError(try RenameHouseholdCommand(householdID: household, commandID: UUID(),
                                                        name: "  ").validate()) {
            XCTAssertEqual($0 as? InventoryCommandError, .emptyHouseholdName)
        }
        XCTAssertNoThrow(try RenameHouseholdCommand(householdID: household, commandID: UUID(),
                                                    name: "Beach House").validate())
    }

    func testReceiptTextIsDiscardedWhenAReviewedRowBecomesACommand() throws {
        let secret = "GREAT VALUE 2% MILK 1GAL 3.99"
        let parsed = ParsedItem(id: .milk, name: "Milk", receiptText: secret, quantity: 2,
                                shelfLifeDays: 7, storage: .fridge)
        let row = PurchaseDraft(reviewing: parsed, itemID: UUID(), stockChangeID: UUID(),
                                purchaseDay: today)
        let command = AddReviewedRowsCommand(householdID: household, commandID: UUID(), rows: [row])
        try command.validate()

        XCTAssertEqual(row.name, "Milk")
        XCTAssertEqual(row.quantity, 2)
        XCTAssertEqual(row.expiryDay, today.adding(days: 7))
        XCTAssertTrue(row.explicitMetadataFields.isEmpty, "a scan guess is not a user edit")
        XCTAssertFalse(containsText(secret, in: command),
                       "raw receipt text must not survive confirmation")
    }

    /// Walks every stored value reachable from the command looking for the text.
    private func containsText(_ needle: String, in value: Any) -> Bool {
        if let text = value as? String { return text.contains(needle) }
        let mirror = Mirror(reflecting: value)
        if mirror.children.isEmpty { return false }
        return mirror.children.contains { containsText(needle, in: $0.value) }
    }
}

final class PurchasePlannerTests: XCTestCase {
    private let today = InventoryDay(year: 2026, month: 8, day: 18)!

    private func existing(name: String = "Milk", art: ItemID = .milk,
                          storage: StorageLocation = .fridge,
                          expiresInDays: Int = 4) -> InventoryItemSnapshot {
        InventoryItemSnapshot(id: UUID(), memberIDs: [UUID()], name: name,
                              normalizedName: NameKey.normalize(name), quantity: 2,
                              artKey: art.rawValue, storage: storage,
                              purchaseDay: today.adding(days: -3)!,
                              expiryDay: today.adding(days: expiresInDays)!,
                              expirySource: .userSet)
    }

    private func draft(name: String = "milk", art: ItemID = .unknown,
                       storage: StorageLocation = .pantry, expiresInDays: Int = 9,
                       explicit: Set<ExplicitMetadataField> = []) -> PurchaseDraft {
        PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: name, quantity: 3,
                      artKey: art.rawValue, storage: storage, purchaseDay: today,
                      expiryDay: today.adding(days: expiresInDays)!,
                      expirySource: .llmEstimate, explicitMetadataFields: explicit)
    }

    func testAFirstPurchaseUsesItsOwnMetadata() {
        let draft = draft()
        let plan = PurchasePlanner.plan(for: draft, matching: nil)

        XCTAssertEqual(plan.rootMetadata.name, "milk")
        XCTAssertEqual(plan.rootMetadata.storage, .pantry)
        XCTAssertEqual(plan.rootMetadata.expiryDay, draft.expiryDay)
        XCTAssertNil(plan.canonicalEdit)
    }

    func testASameNamePurchaseCopiesEstablishedCanonicalMetadata() {
        // A scan guess must not overwrite what the item already shows.
        let established = existing(name: "Milk", art: .milk, storage: .fridge)
        let plan = PurchasePlanner.plan(for: draft(), matching: established)

        XCTAssertEqual(plan.rootMetadata.name, "Milk", "the saved display name is preserved")
        XCTAssertEqual(plan.rootMetadata.artKey, ItemID.milk.rawValue)
        XCTAssertEqual(plan.rootMetadata.storage, .fridge)
        XCTAssertEqual(plan.rootMetadata.purchaseDay, established.purchaseDay)
        XCTAssertEqual(plan.rootMetadata.expiryDay, established.expiryDay)
        XCTAssertEqual(plan.rootMetadata.expirySource, .userSet)
        XCTAssertNil(plan.canonicalEdit)
    }

    func testOnlyExplicitlyEditedFieldsReachTheCanonicalMember() {
        let established = existing()
        let edited = draft(storage: .freezer, expiresInDays: 30, explicit: [.storage])
        let plan = PurchasePlanner.plan(for: edited, matching: established)

        XCTAssertEqual(plan.canonicalEdit?.storage, .freezer)
        XCTAssertNil(plan.canonicalEdit?.expiryDay, "an untouched form default is not an edit")
        XCTAssertNil(plan.canonicalEdit?.artKey)
        // The root itself still starts from the established metadata; the edit
        // is applied once to whichever member ends up canonical.
        XCTAssertEqual(plan.rootMetadata.storage, .fridge)
    }

    func testEveryEditableFieldCanBeOverridden() {
        let plan = PurchasePlanner.plan(
            for: draft(art: .cheese, storage: .freezer, expiresInDays: 30,
                       explicit: [.art, .storage, .expiryDay]),
            matching: existing())

        XCTAssertEqual(plan.canonicalEdit?.artKey, ItemID.cheese.rawValue)
        XCTAssertEqual(plan.canonicalEdit?.storage, .freezer)
        XCTAssertEqual(plan.canonicalEdit?.expiryDay, today.adding(days: 30))
    }

    func testMatchingIsExactNormalizedNameAndSkipsExpiredGroups() {
        let items = [existing(name: "Milk"), existing(name: "Oat Milk"),
                     existing(name: "Butter", expiresInDays: -1)]

        XCTAssertEqual(PurchasePlanner.match(name: "  MILK ", in: items, today: today)?.name, "Milk")
        XCTAssertEqual(PurchasePlanner.match(name: "oat milk", in: items, today: today)?.name,
                       "Oat Milk")
        XCTAssertNil(PurchasePlanner.match(name: "Milkshake", in: items, today: today))
        XCTAssertNil(PurchasePlanner.match(name: "Butter", in: items, today: today),
                     "a fresh buy of something expired is a new batch")
        XCTAssertNil(PurchasePlanner.match(name: "   ", in: items, today: today))
    }

    func testTheMostRecentPurchaseWinsAmongSeveralMatches() {
        let older = existing(name: "Milk")
        let newer = InventoryItemSnapshot(id: UUID(), memberIDs: [UUID()], name: "Milk",
                                          normalizedName: "milk", quantity: 1,
                                          artKey: ItemID.milk.rawValue, storage: .freezer,
                                          purchaseDay: today, expiryDay: today.adding(days: 2)!,
                                          expirySource: .llmEstimate)
        XCTAssertEqual(PurchasePlanner.match(name: "Milk", in: [older, newer], today: today)?.id,
                       newer.id)
    }

    func testTwoRowsOfOneSaveSharingANameDoNotRaceForMetadata() {
        // A review-time rename can collide two receipt lines.
        let first = draft(name: "Milk", art: .milk, storage: .fridge, expiresInDays: 5)
        let second = draft(name: "MILK", art: .unknown, storage: .pantry, expiresInDays: 30)
        let plans = PurchasePlanner.plan(rows: [first, second], in: [], today: today)

        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].rootMetadata.name, "Milk")
        XCTAssertNil(plans[0].canonicalEdit)
        // The second row copies what the first established rather than stamping
        // its own guess and letting UUID order decide which one shows.
        XCTAssertEqual(plans[1].rootMetadata.name, "Milk")
        XCTAssertEqual(plans[1].rootMetadata.storage, .fridge)
        XCTAssertEqual(plans[1].rootMetadata.expiryDay, today.adding(days: 5))
        XCTAssertNil(plans[1].canonicalEdit, "an untouched guess is not an edit")
    }

    func testASecondRowsExplicitEditReachesTheCanonicalMember() {
        let first = draft(name: "Milk", storage: .fridge)
        let second = draft(name: "Milk", storage: .freezer, explicit: [.storage])
        let plans = PurchasePlanner.plan(rows: [first, second], in: [], today: today)

        XCTAssertEqual(plans[1].rootMetadata.storage, .fridge)
        XCTAssertEqual(plans[1].canonicalEdit?.storage, .freezer)
    }

    func testRowsMatchingAnExistingItemAllCopyItsMetadata() {
        let established = existing(name: "Milk", storage: .fridge)
        let plans = PurchasePlanner.plan(rows: [draft(name: "Milk"), draft(name: "milk")],
                                         in: [established], today: today)
        XCTAssertEqual(plans.map(\.rootMetadata.storage), [.fridge, .fridge])
        XCTAssertEqual(plans.map(\.rootMetadata.expiryDay),
                       [established.expiryDay, established.expiryDay])
    }

    func testDifferentlyNamedRowsAreStillPlannedIndependently() {
        let plans = PurchasePlanner.plan(
            rows: [draft(name: "Milk", storage: .fridge), draft(name: "Rice", storage: .pantry)],
            in: [], today: today)
        XCTAssertEqual(plans.map(\.rootMetadata.storage), [.fridge, .pantry])
    }

    func testTiedPurchaseDaysResolveDeterministically() {
        let ids = UUIDOrder.sorted([UUID(), UUID()])
        let candidates = ids.map {
            InventoryItemSnapshot(id: $0, memberIDs: [$0], name: "Milk", normalizedName: "milk",
                                  quantity: 1, artKey: ItemID.milk.rawValue, storage: .fridge,
                                  purchaseDay: today, expiryDay: today.adding(days: 2)!,
                                  expirySource: .llmEstimate)
        }
        XCTAssertEqual(PurchasePlanner.match(name: "Milk", in: candidates, today: today)?.id,
                       ids[1])
        XCTAssertEqual(PurchasePlanner.match(name: "Milk", in: candidates.reversed(),
                                             today: today)?.id, ids[1])
    }
}
