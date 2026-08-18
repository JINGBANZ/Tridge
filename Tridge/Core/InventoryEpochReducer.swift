import Foundation

/// The canonical encoding shared by `HouseholdClearRecord.parentEpochIDsRaw` and
/// `FridgeItemRecord.inventoryEpochContextRaw`: a JSON array of lowercase UUID
/// strings, sorted by UUID byte order, unique, and nonempty.
///
/// Decoding is deliberately exact rather than lenient. Every member reduces the
/// same records independently, so a value that two devices could read
/// differently — or write differently — is corrupt, not merely untidy.
public enum InventoryEpochCodec {
    public static func encode(_ epochIDs: Set<UUID>) -> String? {
        guard !epochIDs.isEmpty else { return nil }
        let quoted = UUIDOrder.sorted(epochIDs).map { "\"\($0.uuidString.lowercased())\"" }
        return "[" + quoted.joined(separator: ",") + "]"
    }

    public static func decode(_ raw: String) -> Set<UUID>? {
        guard let data = raw.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data),
              !strings.isEmpty
        else { return nil }

        var ids: [UUID] = []
        ids.reserveCapacity(strings.count)
        for string in strings {
            guard let id = UUID(uuidString: string) else { return nil }
            ids.append(id)
        }
        let epochIDs = Set(ids)
        // Re-encoding is the canonical-form check: it rejects duplicates,
        // uppercase, padding, and any order but byte order in one comparison.
        guard epochIDs.count == ids.count, encode(epochIDs) == raw else { return nil }
        return epochIDs
    }
}

/// One immutable edge in a Household's causal epoch graph. Clear All records
/// exactly one of these and no item-level stock event (ADR 0009).
public struct HouseholdClearEvent: Hashable, Sendable {
    /// The clear command's id; a retry reuses it.
    public let id: UUID
    /// The leaf this clear creates.
    public let epochID: UUID
    /// The complete frontier the clearing device could see.
    public let parentEpochIDs: Set<UUID>
    /// One more than the greatest parent revision.
    public let revision: Int64
    public let occurredAt: Date

    public init(id: UUID, epochID: UUID, parentEpochIDs: Set<UUID>, revision: Int64,
                occurredAt: Date) {
        self.id = id
        self.epochID = epochID
        self.parentEpochIDs = parentEpochIDs
        self.revision = revision
        self.occurredAt = occurredAt
    }
}

/// Content-free findings about the epoch graph. A corrupt record is dropped; it
/// must never be able to suppress otherwise valid inventory.
public enum EpochIntegrityIssue: Hashable, Sendable {
    /// One record id carrying two different payloads.
    case conflictingRecord(UUID)
    /// One epoch id defined twice with different payloads.
    case conflictingEpoch(UUID)
    /// Revision is not positive, or not one more than its greatest parent.
    case invalidRevision(UUID)
    /// Empty parents, a self-parent, or an attempt to redefine the initial epoch.
    case invalidParents(UUID)
    /// The record can only ever descend from itself.
    case cycle(UUID)
}

public struct InventoryEpochReduction: Hashable, Sendable {
    /// Reachable epochs with no outgoing valid clear edge.
    public let frontier: Set<UUID>
    public let revisions: [UUID: Int64]
    /// Records whose parents have not arrived. Waiting is normal — an offline
    /// peer is never evidence of corruption, so these stay pending indefinitely.
    public let pendingRecordIDs: Set<UUID>
    public let issues: [EpochIntegrityIssue]

    /// An item is current while **at least one** epoch it captured at creation
    /// is still a leaf. The captured set is independent supporting branches,
    /// not an all-or-nothing dependency.
    public func supports(context: Set<UUID>) -> Bool {
        !context.isDisjoint(with: frontier)
    }
}

public enum InventoryEpochReducer {
    /// Reduces one Household's clear records into its current causal frontier.
    public static func reduce(initialEpochID: UUID,
                              clears: [HouseholdClearEvent]) -> InventoryEpochReduction {
        var issues: Set<EpochIntegrityIssue> = []
        let candidates = deduplicate(clears, initialEpochID: initialEpochID, issues: &issues)

        var revisions: [UUID: Int64] = [initialEpochID: 0]
        var accepted: [HouseholdClearEvent] = []
        var remaining = candidates

        // Repeatedly accept every record whose parents have all resolved. Import
        // order therefore cannot change the outcome.
        var progressed = true
        while progressed {
            progressed = false
            var deferred: [HouseholdClearEvent] = []
            for record in remaining {
                let parentRevisions = record.parentEpochIDs.compactMap { revisions[$0] }
                guard parentRevisions.count == record.parentEpochIDs.count else {
                    deferred.append(record)
                    continue
                }
                progressed = true
                guard record.revision > 0,
                      record.revision == nextRevision(after: parentRevisions) else {
                    issues.insert(.invalidRevision(record.id))
                    continue
                }
                revisions[record.epochID] = record.revision
                accepted.append(record)
            }
            remaining = deferred
        }

        for record in remaining where descendsFromItself(record, among: remaining) {
            issues.insert(.cycle(record.id))
        }
        let pending = remaining.filter { !issues.contains(.cycle($0.id)) }

        let superseded = accepted.reduce(into: Set<UUID>()) { $0.formUnion($1.parentEpochIDs) }
        return InventoryEpochReduction(frontier: Set(revisions.keys).subtracting(superseded),
                                       revisions: revisions,
                                       pendingRecordIDs: Set(pending.map(\.id)),
                                       issues: issues.sorted { $0.sortKey < $1.sortKey })
    }

    /// One more than the greatest parent revision, or nil when the parents are
    /// empty or the successor would leave `Int64`.
    public static func nextRevision(after parentRevisions: some Sequence<Int64>) -> Int64? {
        guard let greatest = parentRevisions.max() else { return nil }
        let (next, overflowed) = greatest.addingReportingOverflow(1)
        return overflowed ? nil : next
    }

    /// Builds the Clear All barrier for the frontier a device can currently see.
    /// Reusing the ids on retry produces an identical record, which reduces once.
    public static func makeClear(recordID: UUID, epochID: UUID, occurredAt: Date,
                                 from reduction: InventoryEpochReduction) -> HouseholdClearEvent? {
        let parents = reduction.frontier
        guard !parents.contains(epochID),
              let revision = nextRevision(after: parents.compactMap { reduction.revisions[$0] })
        else { return nil }
        return HouseholdClearEvent(id: recordID, epochID: epochID, parentEpochIDs: parents,
                                   revision: revision, occurredAt: occurredAt)
    }

    /// Collapses identical retries and rejects records that are corrupt on their
    /// own terms, before any graph reasoning.
    private static func deduplicate(_ clears: [HouseholdClearEvent], initialEpochID: UUID,
                                    issues: inout Set<EpochIntegrityIssue>)
    -> [HouseholdClearEvent] {
        var byRecordID: [UUID: HouseholdClearEvent] = [:]
        var conflictingRecordIDs: Set<UUID> = []
        for record in clears {
            guard !record.parentEpochIDs.isEmpty,
                  !record.parentEpochIDs.contains(record.epochID),
                  record.epochID != initialEpochID
            else {
                issues.insert(.invalidParents(record.id))
                conflictingRecordIDs.insert(record.id)
                continue
            }
            if let rival = byRecordID[record.id], rival != record {
                issues.insert(.conflictingRecord(record.id))
                conflictingRecordIDs.insert(record.id)
            }
            byRecordID[record.id] = record
        }

        var byEpochID: [UUID: HouseholdClearEvent] = [:]
        var conflictingEpochIDs: Set<UUID> = []
        for record in byRecordID.values where !conflictingRecordIDs.contains(record.id) {
            // A second record for the same epoch is harmless when it says the
            // same thing, and corrupt when it does not.
            if let rival = byEpochID[record.epochID] {
                guard rival.describesSameEpoch(as: record) else {
                    issues.insert(.conflictingEpoch(record.epochID))
                    conflictingEpochIDs.insert(record.epochID)
                    byEpochID[record.epochID] = record
                    continue
                }
                // Same epoch stated twice under different command ids: keep the
                // lower one so peers agree on which record id is pending or
                // diagnosed, not merely on the frontier.
                guard UUIDOrder.isBefore(record.id, rival.id) else { continue }
            }
            byEpochID[record.epochID] = record
        }

        return byEpochID.values.filter { !conflictingEpochIDs.contains($0.epochID) }
    }

    /// True when following the record's unresolved ancestry returns to its own
    /// epoch — the only cycle shape provable without the missing records.
    private static func descendsFromItself(_ record: HouseholdClearEvent,
                                           among unresolved: [HouseholdClearEvent]) -> Bool {
        let producers = Dictionary(unresolved.map { ($0.epochID, $0) }, uniquingKeysWith: { first, _ in first })
        var frontier = Array(record.parentEpochIDs)
        var seen: Set<UUID> = []
        while let epoch = frontier.popLast() {
            if epoch == record.epochID { return true }
            guard seen.insert(epoch).inserted, let parent = producers[epoch] else { continue }
            frontier.append(contentsOf: parent.parentEpochIDs)
        }
        return false
    }
}

extension HouseholdClearEvent {
    /// Two records describe the same epoch when only their command ids differ.
    fileprivate func describesSameEpoch(as other: HouseholdClearEvent) -> Bool {
        epochID == other.epochID && parentEpochIDs == other.parentEpochIDs
            && revision == other.revision && occurredAt == other.occurredAt
    }
}

extension EpochIntegrityIssue {
    fileprivate var sortKey: String {
        switch self {
        case .conflictingRecord(let id): "1.\(id.uuidString)"
        case .conflictingEpoch(let id): "2.\(id.uuidString)"
        case .invalidRevision(let id): "3.\(id.uuidString)"
        case .invalidParents(let id): "4.\(id.uuidString)"
        case .cycle(let id): "5.\(id.uuidString)"
        }
    }
}
