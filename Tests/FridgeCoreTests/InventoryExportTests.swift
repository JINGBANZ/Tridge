import XCTest
@testable import FridgeCore

/// The export document's shape: what it carries, what it must never carry, and
/// that it survives a round trip.
final class InventoryExportTests: XCTestCase {
    private let today = InventoryDay(year: 2026, month: 8, day: 26)!
    private let instant = Date(timeIntervalSince1970: 1_787_097_600)

    private func item(_ name: String, quantity: Int64 = 2) -> InventoryItemSnapshot {
        let id = UUID()
        return InventoryItemSnapshot(id: id, memberIDs: [id], name: name,
                                     normalizedName: NameKey.normalize(name),
                                     quantity: quantity, artKey: ItemID.milk.rawValue,
                                     storage: .fridge, purchaseDay: today,
                                     expiryDay: today.adding(days: 5)!,
                                     expirySource: .llmEstimate)
    }

    private func root(_ name: String) -> PhysicalItemSnapshot {
        PhysicalItemSnapshot(id: UUID(), name: name, inventoryContext: [UUID()],
                             artKey: ItemID.milk.rawValue, storage: .fridge,
                             purchaseDay: today, expiryDay: today.adding(days: 5)!,
                             expirySource: .llmEstimate, createdAt: instant,
                             modifiedAt: instant)
    }

    private func document() throws -> InventoryExportDocument {
        let milk = root("Milk")
        let claim = try XCTUnwrap(ItemMergeClaim(UUID(), UUID()))
        return InventoryExportDocument(
            exportedAt: instant,
            householdName: "Home",
            items: [item("Milk")].map(InventoryExportDocument.LogicalItem.init),
            physicalItems: [milk].map(InventoryExportDocument.PhysicalItem.init),
            stockOperations: [
                StockEvent(id: UUID(), delta: 2, reason: .acquired, occurredAt: instant),
                StockEvent(id: UUID(), delta: -1, reason: .eaten, occurredAt: instant),
                StockEvent(id: UUID(), delta: 0, reason: .deleted, occurredAt: instant),
            ].map { InventoryExportDocument.StockOperation($0, itemID: milk.id) },
            itemMerges: [InventoryExportDocument.MergeClaim(
                ItemMergeClaimRecord(id: UUID(), claim: claim))],
            clearEvents: [InventoryExportDocument.ClearEvent(
                HouseholdClearEvent(id: UUID(), epochID: UUID(), parentEpochIDs: [UUID()],
                                    revision: 1, occurredAt: instant))])
    }

    func testTheDocumentRoundTrips() throws {
        let original = try document()

        let restored = try InventoryExportDocument.decoded(from: original.encoded())

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.formatVersion, InventoryExportDocument.currentFormatVersion)
    }

    /// Zero, deleted, and superseded rows are the point: an export that only
    /// carried current stock would not be the user's history.
    func testEveryOperationIsCarriedIncludingTerminalOnes() throws {
        let reasons = Set(try document().stockOperations.map(\.reason))

        XCTAssertEqual(reasons, ["acquired", "eaten", "deleted"])
    }

    func testTheDocumentCarriesNoRestrictedField() throws {
        let json = try XCTUnwrap(String(data: try document().encoded(), encoding: .utf8))
            .lowercased()

        for restricted in ["receipt", "participant", "share", "invitation", "account",
                           "diagnostic", "email"] {
            XCTAssertFalse(json.contains(restricted),
                           "the export must not carry \(restricted) data")
        }
    }

    func testTheFileNameNamesTheFridgeWithoutChangingWhatAPathMeans() {
        func name(_ household: String) -> String {
            InventoryExportDocument(exportedAt: instant, householdName: household, items: [],
                                    physicalItems: [], stockOperations: [], itemMerges: [],
                                    clearEvents: []).suggestedFileName
        }

        XCTAssertEqual(name("Beach House"), "Beach House Inventory.json")
        XCTAssertEqual(name("../../etc"), "------etc Inventory.json")
        XCTAssertEqual(name("a/b"), "a-b Inventory.json")
        XCTAssertEqual(name("   "), "Fridge Inventory.json")
        XCTAssertEqual(name(""), "Fridge Inventory.json")
    }

    /// Dates encode as ISO-8601 and days as their bare ordinal, so a reader
    /// needs no Apple framework to make sense of the file.
    func testDatesAndDaysEncodePortably() throws {
        let json = try XCTUnwrap(String(data: try document().encoded(), encoding: .utf8))

        XCTAssertTrue(json.contains("2026-08-19T00:00:00Z"))
        XCTAssertTrue(json.contains("\"purchaseDay\" : \(today.ordinal)"))
    }
}
