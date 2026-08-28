import CloudKit
import CoreData

extension HouseholdRecord {
    /// Stands in for the id of a record that cannot name itself.
    static let unidentifiable = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The validated value projection of this record.
    ///
    /// Every attribute is optional in the model because CloudKit requires it,
    /// so validation happens here rather than leaking optionals into the
    /// domain. A record that fails is omitted from the UI and left intact for
    /// diagnostics — never repaired or deleted.
    func snapshot(ownership: HouseholdOwnership, isShared: Bool) throws -> HouseholdSnapshot {
        guard let id else {
            // No id means nothing can identify the finding either; the zero
            // UUID stands in for "this record cannot name itself".
            throw RecordIntegrityIssue(entity: .household, id: Self.unidentifiable,
                                       category: .missingValue)
        }
        guard let createdAt else {
            throw RecordIntegrityIssue(entity: .household, id: id, category: .missingValue)
        }
        guard initialInventoryEpochID != nil else {
            throw RecordIntegrityIssue(entity: .household, id: id, category: .invalidContext)
        }
        let name = self.name ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordIntegrityIssue(entity: .household, id: id, category: .invalidName)
        }
        return HouseholdSnapshot(id: id, name: name, ownership: ownership,
                                 createdAt: createdAt, isShared: isShared)
    }
}

extension HouseholdClearRecord {
    /// The validated value form the Linux-testable epoch reducer works with.
    func event() throws -> HouseholdClearEvent {
        let id = self.id ?? HouseholdRecord.unidentifiable
        func corrupt(_ category: RecordIntegrityIssue.Category) -> RecordIntegrityIssue {
            RecordIntegrityIssue(entity: .householdClear, id: id, category: category)
        }

        guard self.id != nil, let epochID, let occurredAt else { throw corrupt(.missingValue) }
        guard let raw = parentEpochIDsRaw, let parents = InventoryEpochCodec.decode(raw) else {
            throw corrupt(.invalidContext)
        }
        guard occurredAt.timeIntervalSince1970.isFinite else { throw corrupt(.invalidInstant) }
        return HouseholdClearEvent(id: id, epochID: epochID, parentEpochIDs: parents,
                                   revision: revision, occurredAt: occurredAt)
    }
}

extension HouseholdRecord {
    /// This Household's causal epoch graph, reduced.
    ///
    /// A corrupt clear record is dropped rather than allowed to suppress
    /// otherwise valid inventory — the reducer treats the ones it can read as
    /// the whole graph.
    func epochReduction() throws -> InventoryEpochReduction {
        guard let initialInventoryEpochID else {
            throw RecordIntegrityIssue(entity: .household, id: id ?? Self.unidentifiable,
                                       category: .invalidContext)
        }
        let clears = clearEvents.compactMap { try? $0.event() }
        return InventoryEpochReducer.reduce(initialEpochID: initialInventoryEpochID,
                                            clears: clears)
    }

    /// The complete causal frontier a new purchase root must capture, so a
    /// concurrent Clear All can judge it by context rather than by clock.
    func inventoryFrontier() throws -> Set<UUID> {
        try epochReduction().frontier
    }
}

extension PersistenceController {
    /// Creates this account's first owned Household in the private store.
    ///
    /// Synchronous by design: it is a single row written once at bootstrap,
    /// before any inventory UI exists, and keeping it inside the caller's turn
    /// means there is no extra async boundary to register and drain.
    /// Returns the snapshot it wrote rather than re-reading it: the view
    /// context merges a writer's save asynchronously, so a fetch here could
    /// legitimately come back empty.
    func createOwnedHousehold(named name: String) throws -> HouseholdSnapshot {
        let context = newWriterContext()
        var result: Result<HouseholdSnapshot, Error>?
        context.performAndWait {
            result = Result {
                let household = HouseholdRecord(context: context)
                let id = UUID()
                let now = Date()
                household.id = id
                household.name = name
                // Revision 0 of the causal epoch graph: the frontier until the
                // first Clear All.
                household.initialInventoryEpochID = UUID()
                household.createdAt = now
                household.modifiedAt = now
                try StoreRouting.assign([household], to: privateStore, in: context)
                try context.save()
                // Just created in this account's own private store, so it is
                // owned and cannot yet be shared.
                return HouseholdSnapshot(id: id, name: name, ownership: .owned,
                                         createdAt: now, isShared: false)
            }
        }
        // `performAndWait` runs the body before returning, so this is set.
        return try result!.get()
    }

    /// Every valid Household across both stores, with the integrity findings
    /// for the ones that were omitted.
    ///
    /// Ownership comes from the store the record lives in, which is the only
    /// authority the contract accepts — an optional participant field is not.
    ///
    /// Share status is deliberately *not* answered here. Share metadata does
    /// not appear in persistent history, so it is refreshed on its own schedule
    /// by `HouseholdSharing`; every snapshot leaves here unshared and the
    /// coordinator overlays what the container currently reports.
    func householdSnapshots() -> (valid: [HouseholdSnapshot], issues: [RecordIntegrityIssue]) {
        let request = HouseholdRecord.fetchRequest()
        guard let records = try? viewContext.fetch(request) else { return ([], []) }

        var valid: [HouseholdSnapshot] = []
        var issues: [RecordIntegrityIssue] = []
        for record in records {
            guard let ownership = ownership(of: record) else { continue }
            do {
                valid.append(try record.snapshot(ownership: ownership, isShared: false))
            } catch let issue as RecordIntegrityIssue {
                issues.append(issue)
            } catch {
                continue
            }
        }
        return (valid, issues)
    }
}

extension HouseholdSnapshot {
    /// The same Household with its current share status applied.
    func withShareState(isShared: Bool) -> HouseholdSnapshot {
        HouseholdSnapshot(id: id, name: name, ownership: ownership, createdAt: createdAt,
                          isShared: isShared)
    }
}
