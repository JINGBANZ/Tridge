import XCTest
@testable import FridgeCore

final class InventoryEpochCodecTests: XCTestCase {
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    func testEncodesLowercaseSortedJSON() {
        let encoded = InventoryEpochCodec.encode([id(2), id(1)])
        XCTAssertEqual(encoded, #"["01000000-0000-0000-0000-000000000000","02000000-0000-0000-0000-000000000000"]"#)
    }

    func testEmptyContextHasNoCanonicalEncoding() {
        XCTAssertNil(InventoryEpochCodec.encode([]))
    }

    func testRoundTrips() {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        XCTAssertEqual(InventoryEpochCodec.decode(InventoryEpochCodec.encode(ids)!), ids)
    }

    func testRejectsNoncanonicalEncodings() {
        let sorted = UUIDOrder.sorted([id(1), id(2)]).map { $0.uuidString.lowercased() }
        XCTAssertNil(InventoryEpochCodec.decode("[]"), "empty")
        XCTAssertNil(InventoryEpochCodec.decode(""), "not JSON")
        XCTAssertNil(InventoryEpochCodec.decode("not json"), "not JSON")
        XCTAssertNil(InventoryEpochCodec.decode(#"{"a":1}"#), "not an array")
        XCTAssertNil(InventoryEpochCodec.decode("[1,2]"), "not strings")
        XCTAssertNil(InventoryEpochCodec.decode(#"["nope"]"#), "not a UUID")
        let lettered = UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789")!.uuidString
        XCTAssertNil(InventoryEpochCodec.decode(#"["\#(lettered.uppercased())"]"#), "uppercase")
        XCTAssertEqual(InventoryEpochCodec.decode(#"["\#(lettered.lowercased())"]"#)?.count, 1)
        XCTAssertNil(InventoryEpochCodec.decode(#"["\#(sorted[1])","\#(sorted[0])"]"#), "unsorted")
        XCTAssertNil(InventoryEpochCodec.decode(#"["\#(sorted[0])","\#(sorted[0])"]"#), "duplicate")
        XCTAssertNil(InventoryEpochCodec.decode(#"[ "\#(sorted[0])" ]"#), "padded")
    }
}

final class InventoryEpochReducerTests: XCTestCase {
    private let initial = UUID()

    private func clear(_ epoch: UUID, parents: Set<UUID>, revision: Int64,
                       recordID: UUID = UUID(), at instant: TimeInterval = 0)
    -> HouseholdClearRecord {
        HouseholdClearRecord(id: recordID, epochID: epoch, parentEpochIDs: parents,
                             revision: revision, occurredAt: Date(timeIntervalSince1970: instant))
    }

    func testFreshHouseholdFrontierIsItsInitialEpoch() {
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [])
        XCTAssertEqual(reduction.frontier, [initial])
        XCTAssertEqual(reduction.revisions[initial], 0)
        XCTAssertTrue(reduction.issues.isEmpty)
    }

    func testClearAllAdvancesTheFrontier() {
        let cleared = UUID()
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(cleared, parents: [initial], revision: 1)])

        XCTAssertEqual(reduction.frontier, [cleared])
        XCTAssertFalse(reduction.supports(context: [initial]), "pre-clear items are suppressed")
        XCTAssertTrue(reduction.supports(context: [cleared]))
    }

    func testReductionIgnoresImportOrder() {
        let first = UUID(), second = UUID()
        let records = [clear(first, parents: [initial], revision: 1),
                       clear(second, parents: [first], revision: 2)]
        let forward = InventoryEpochReducer.reduce(initialEpochID: initial, clears: records)
        let reversed = InventoryEpochReducer.reduce(initialEpochID: initial,
                                                    clears: records.reversed())
        XCTAssertEqual(forward.frontier, [second])
        XCTAssertEqual(forward, reversed)
    }

    func testIdenticalRetriedRecordsReduceOnce() {
        let cleared = UUID(), recordID = UUID()
        let record = clear(cleared, parents: [initial], revision: 1, recordID: recordID)
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial,
                                                     clears: [record, record, record])
        XCTAssertEqual(reduction.frontier, [cleared])
        XCTAssertTrue(reduction.issues.isEmpty)
    }

    func testConcurrentClearsStayAsSeparateBranches() {
        // Both members clear while offline from the same frontier.
        let mine = UUID(), theirs = UUID()
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(mine, parents: [initial], revision: 1),
                     clear(theirs, parents: [initial], revision: 1)])

        XCTAssertEqual(reduction.frontier, [mine, theirs])
        XCTAssertFalse(reduction.supports(context: [initial]))
        // Groceries added after either clear survive the merge.
        XCTAssertTrue(reduction.supports(context: [mine]))
        XCTAssertTrue(reduction.supports(context: [theirs]))
    }

    func testAnItemSupportedByASecondBranchSurvivesAClearOfTheFirst() {
        let mine = UUID(), theirs = UUID(), later = UUID()
        // An item added after both branches were visible captures both.
        let context: Set<UUID> = [mine, theirs]
        let branches = [clear(mine, parents: [initial], revision: 1),
                        clear(theirs, parents: [initial], revision: 1)]

        // A device that has only imported "mine" clears just that branch.
        let partial = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: branches + [clear(later, parents: [mine], revision: 2)])
        XCTAssertEqual(partial.frontier, [theirs, later])
        XCTAssertTrue(partial.supports(context: context), "still supported by the other branch")

        // A clear that names every observed leaf supersedes them all.
        let complete = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: branches + [clear(later, parents: [mine, theirs], revision: 2)])
        XCTAssertEqual(complete.frontier, [later])
        XCTAssertFalse(complete.supports(context: context))
        XCTAssertTrue(complete.supports(context: [later]))
    }

    func testARecordWaitsForAParentThatHasNotArrivedYet() {
        let missing = UUID(), child = UUID()
        let orphan = clear(child, parents: [missing], revision: 2)
        let pending = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [orphan])

        XCTAssertEqual(pending.frontier, [initial], "an unresolved clear cannot clear anything")
        XCTAssertEqual(pending.pendingRecordIDs, [orphan.id])
        XCTAssertTrue(pending.issues.isEmpty, "waiting is not corruption")

        // The parent finally imports.
        let resolved = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [orphan, clear(missing, parents: [initial], revision: 1)])
        XCTAssertEqual(resolved.frontier, [child])
        XCTAssertTrue(resolved.pendingRecordIDs.isEmpty)
    }

    func testConflictingRecordIdIsDroppedWithoutSuppressingValidInventory() {
        let recordID = UUID(), valid = UUID()
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(UUID(), parents: [initial], revision: 1, recordID: recordID),
                     clear(UUID(), parents: [initial], revision: 1, recordID: recordID),
                     clear(valid, parents: [initial], revision: 1)])

        XCTAssertEqual(reduction.frontier, [valid])
        XCTAssertEqual(reduction.issues, [.conflictingRecord(recordID)])
    }

    func testConflictingEpochIdIsDropped() {
        let epoch = UUID(), valid = UUID()
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(epoch, parents: [initial], revision: 1),
                     clear(epoch, parents: [initial], revision: 1, at: 99),
                     clear(valid, parents: [initial], revision: 1)])

        XCTAssertEqual(reduction.frontier, [valid])
        XCTAssertEqual(reduction.issues, [.conflictingEpoch(epoch)])
    }

    func testRevisionMustBeOneMoreThanItsGreatestParent() {
        let first = UUID(), wrong = UUID()
        let bad = clear(wrong, parents: [first], revision: 5)
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(first, parents: [initial], revision: 1), bad])

        XCTAssertEqual(reduction.frontier, [first], "the valid clear still applies")
        XCTAssertEqual(reduction.issues, [.invalidRevision(bad.id)])
    }

    func testNonpositiveRevisionIsCorrupt() {
        let bad = clear(UUID(), parents: [initial], revision: 0)
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [bad])
        XCTAssertEqual(reduction.frontier, [initial])
        XCTAssertEqual(reduction.issues, [.invalidRevision(bad.id)])
    }

    func testEmptyOrSelfReferentialParentsAreCorrupt() {
        let selfParent = UUID()
        let empty = clear(UUID(), parents: [], revision: 1)
        let loop = clear(selfParent, parents: [selfParent], revision: 1)
        let redefined = clear(initial, parents: [initial], revision: 1)
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial,
                                                     clears: [empty, loop, redefined])

        XCTAssertEqual(reduction.frontier, [initial])
        XCTAssertEqual(Set(reduction.issues), [.invalidParents(empty.id), .invalidParents(loop.id),
                                               .invalidParents(redefined.id)])
        XCTAssertTrue(reduction.pendingRecordIDs.isEmpty)
    }

    func testAProvableCycleIsCorruptRatherThanPendingForever() {
        let left = UUID(), right = UUID()
        let a = clear(left, parents: [right], revision: 2)
        let b = clear(right, parents: [left], revision: 3)
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [a, b])

        XCTAssertEqual(reduction.frontier, [initial])
        XCTAssertEqual(Set(reduction.issues), [.cycle(a.id), .cycle(b.id)])
        XCTAssertTrue(reduction.pendingRecordIDs.isEmpty)
    }

    func testNextRevisionRejectsOverflowInsteadOfWrapping() {
        XCTAssertEqual(InventoryEpochReducer.nextRevision(after: [0, 4, 2]), 5)
        XCTAssertNil(InventoryEpochReducer.nextRevision(after: []))
        XCTAssertNil(InventoryEpochReducer.nextRevision(after: [.max]))
    }

    func testMakeClearCapturesTheWholeCurrentFrontier() {
        let mine = UUID(), theirs = UUID()
        let reduction = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(mine, parents: [initial], revision: 1),
                     clear(theirs, parents: [initial], revision: 1)])

        let recordID = UUID(), epochID = UUID()
        let next = InventoryEpochReducer.makeClear(recordID: recordID, epochID: epochID,
                                                   occurredAt: Date(timeIntervalSince1970: 10),
                                                   from: reduction)
        XCTAssertEqual(next?.parentEpochIDs, [mine, theirs])
        XCTAssertEqual(next?.revision, 2)

        let advanced = InventoryEpochReducer.reduce(
            initialEpochID: initial,
            clears: [clear(mine, parents: [initial], revision: 1),
                     clear(theirs, parents: [initial], revision: 1), next!])
        XCTAssertEqual(advanced.frontier, [epochID])
    }

    func testRetryingClearAllWithTheSameIdsIsIdempotent() {
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [])
        let recordID = UUID(), epochID = UUID()
        let first = InventoryEpochReducer.makeClear(recordID: recordID, epochID: epochID,
                                                    occurredAt: Date(timeIntervalSince1970: 5),
                                                    from: reduction)!
        let retry = InventoryEpochReducer.makeClear(recordID: recordID, epochID: epochID,
                                                    occurredAt: Date(timeIntervalSince1970: 5),
                                                    from: reduction)!
        let applied = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [first, retry])
        XCTAssertEqual(applied.frontier, [epochID])
        XCTAssertTrue(applied.issues.isEmpty)
    }

    func testAnItemCarryingNoContextIsNeverSupported() {
        let reduction = InventoryEpochReducer.reduce(initialEpochID: initial, clears: [])
        XCTAssertFalse(reduction.supports(context: []))
    }
}
