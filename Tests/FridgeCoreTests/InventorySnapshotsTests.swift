import XCTest
@testable import FridgeCore

final class PhysicalItemSnapshotTests: XCTestCase {
    private let epoch = UUID()

    private func validating(name: String = "Whole Milk",
                            normalizedName: String? = nil,
                            contextRaw: String? = nil,
                            artKey: String = ItemID.milk.rawValue,
                            storageRaw: String = StorageLocation.fridge.rawValue,
                            purchaseOrdinal: Int32 = 20_683,
                            expiryOrdinal: Int32 = 20_690,
                            expirySourceRaw: String = ExpirySource.llmEstimate.rawValue,
                            createdAt: Date = Date(timeIntervalSince1970: 0),
                            modifiedAt: Date = Date(timeIntervalSince1970: 0)) throws
    -> PhysicalItemSnapshot {
        try PhysicalItemSnapshot(
            id: UUID(),
            name: name,
            normalizedName: normalizedName ?? NameKey.normalize(name),
            inventoryEpochContextRaw: contextRaw ?? InventoryEpochCodec.encode([epoch])!,
            artKey: artKey,
            storageRaw: storageRaw,
            purchaseDayOrdinal: purchaseOrdinal,
            expiryDayOrdinal: expiryOrdinal,
            expirySourceRaw: expirySourceRaw,
            createdAt: createdAt,
            modifiedAt: modifiedAt)
    }

    private func assertCorrupt(_ category: RecordIntegrityIssue.Category,
                               _ build: () throws -> PhysicalItemSnapshot,
                               line: UInt = #line) {
        XCTAssertThrowsError(try build(), line: line) { error in
            XCTAssertEqual((error as? RecordIntegrityIssue)?.category, category, line: line)
            XCTAssertEqual((error as? RecordIntegrityIssue)?.entity, .item, line: line)
        }
    }

    func testValidatedRecordMapsToTypedValues() throws {
        let item = try validating()
        XCTAssertEqual(item.normalizedName, "whole milk")
        XCTAssertEqual(item.storage, .fridge)
        XCTAssertEqual(item.expirySource, .llmEstimate)
        XCTAssertEqual(item.inventoryContext, [epoch])
        XCTAssertEqual(item.expiryDay, InventoryDay(year: 2026, month: 8, day: 25))
        XCTAssertEqual(item.artID, .milk)
        XCTAssertEqual(item.foodCategory, .dairy)
    }

    func testNormalizedNameMustMatchTheSavedName() {
        // Names are immutable once saved, so a drifted key is corrupt data.
        assertCorrupt(.invalidName) { try validating(name: "Milk", normalizedName: "cheese") }
    }

    func testEmptyNameIsCorrupt() {
        assertCorrupt(.invalidName) { try validating(name: "   ") }
    }

    func testInvalidRawEnumsAreCorrupt() {
        assertCorrupt(.invalidRawValue) { try validating(storageRaw: "cupboard") }
        assertCorrupt(.invalidRawValue) { try validating(expirySourceRaw: "vibes") }
    }

    func testUnknownArtKeyDegradesInsteadOfFailing() throws {
        // A newer build's vocabulary id must not make the row corrupt.
        let item = try validating(artKey: "quinoa_from_the_future")
        XCTAssertEqual(item.artID, .unknown)
        XCTAssertEqual(item.artKey, "quinoa_from_the_future", "the original id is preserved")
    }

    func testInvalidDayOrdinalsAreCorrupt() {
        assertCorrupt(.invalidDay) { try validating(purchaseOrdinal: .max) }
        assertCorrupt(.invalidDay) { try validating(expiryOrdinal: .min) }
    }

    func testNoncanonicalInventoryContextIsCorrupt() {
        assertCorrupt(.invalidContext) { try validating(contextRaw: "[]") }
        assertCorrupt(.invalidContext) { try validating(contextRaw: "nonsense") }
    }

    func testNonfiniteInstantsAreCorrupt() {
        assertCorrupt(.invalidInstant) {
            try validating(createdAt: Date(timeIntervalSince1970: .infinity))
        }
    }

    func testIntegrityIssuesCarryNoContent() {
        // Diagnostics may name the entity, id, and category — never the item.
        let issue = RecordIntegrityIssue(entity: .item, id: UUID(), category: .invalidName)
        XCTAssertEqual(issue.diagnosticDescription,
                       "item \(issue.id.uuidString) invalidName")
    }
}
