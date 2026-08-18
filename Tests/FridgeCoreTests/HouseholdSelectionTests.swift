import XCTest
@testable import FridgeCore

final class HouseholdSelectionTests: XCTestCase {
    private func household(_ ownership: HouseholdOwnership, createdDaysAgo: Int,
                           id: UUID = UUID(), name: String = "Home") -> HouseholdSnapshot {
        HouseholdSnapshot(id: id, name: name, ownership: ownership,
                          createdAt: Date(timeIntervalSince1970: -Double(createdDaysAgo) * 86_400),
                          isShared: false)
    }

    func testAnAccessibleSavedSelectionIsKept() {
        let saved = household(.received, createdDaysAgo: 1)
        let outcome = HouseholdSelection.choose(saved: saved.id,
                                                available: [household(.owned, createdDaysAgo: 9), saved],
                                                hasCompletedInitialImport: true)
        XCTAssertEqual(outcome, .select(saved.id))
    }

    func testASavedSelectionThatNoLongerResolvesFallsBack() {
        // Left, revoked, purged, or deleted: run the fallback immediately.
        let owned = household(.owned, createdDaysAgo: 3)
        let outcome = HouseholdSelection.choose(saved: UUID(), available: [owned],
                                                hasCompletedInitialImport: true)
        XCTAssertEqual(outcome, .select(owned.id))
    }

    func testTheOldestOwnedHouseholdWinsBeforeAnyReceivedOne() {
        let newerOwned = household(.owned, createdDaysAgo: 2)
        let olderOwned = household(.owned, createdDaysAgo: 10)
        let oldestReceived = household(.received, createdDaysAgo: 50)
        let outcome = HouseholdSelection.choose(saved: nil,
                                                available: [newerOwned, oldestReceived, olderOwned],
                                                hasCompletedInitialImport: true)
        XCTAssertEqual(outcome, .select(olderOwned.id))
    }

    func testAReceivedHouseholdIsChosenOnlyWhenNoneIsOwned() {
        let older = household(.received, createdDaysAgo: 10)
        let newer = household(.received, createdDaysAgo: 1)
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: [newer, older],
                                                 hasCompletedInitialImport: true),
                       .select(older.id))
    }

    func testCreationDateTiesBreakByUuidByteOrder() {
        let ids = UUIDOrder.sorted([UUID(), UUID(), UUID()])
        let tied = ids.map { household(.owned, createdDaysAgo: 4, id: $0) }
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: tied,
                                                 hasCompletedInitialImport: true),
                       .select(ids[0]))
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: tied.reversed(),
                                                 hasCompletedInitialImport: true),
                       .select(ids[0]))
    }

    func testAnEmptyAccountCreatesMyFridgeOnlyAfterTheBootstrapBarrier() {
        // Otherwise a fresh install duplicates the household still importing.
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: [],
                                                 hasCompletedInitialImport: false),
                       .waitForInitialImport)
        XCTAssertEqual(HouseholdSelection.choose(saved: UUID(), available: [],
                                                 hasCompletedInitialImport: false),
                       .waitForInitialImport)
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: [],
                                                 hasCompletedInitialImport: true),
                       .createDefaultHousehold)
        XCTAssertEqual(HouseholdSelection.defaultHouseholdName, "My Fridge")
    }

    func testAnExistingCacheRendersWithoutWaitingForAFreshImport() {
        let owned = household(.owned, createdDaysAgo: 3)
        XCTAssertEqual(HouseholdSelection.choose(saved: owned.id, available: [owned],
                                                 hasCompletedInitialImport: false),
                       .select(owned.id))
        XCTAssertEqual(HouseholdSelection.choose(saved: nil, available: [owned],
                                                 hasCompletedInitialImport: false),
                       .select(owned.id))
    }
}
