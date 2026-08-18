import Foundation

/// Why stock moved. Every reason constrains its delta, so an imported record
/// whose pair disagrees is corrupt rather than merely surprising.
public enum StockReason: String, Codable, CaseIterable, Sendable {
    /// The initial stock of one fresh manual or receipt purchase root.
    case acquired
    /// Committing the quantity field: `target - currentLocalProjection`.
    case adjusted
    case eaten
    case tossed
    /// Active inventory copied forward when an owner stops sharing.
    case preserved
    /// The immutable user-deletion marker. Terminal for the whole logical item.
    case deleted

    func permits(delta: Int64) -> Bool {
        switch self {
        case .acquired, .preserved: delta > 0
        case .adjusted: delta != 0
        case .eaten, .tossed: delta == -1
        case .deleted: delta == 0
        }
    }
}

/// One immutable stock operation. Household members compose these instead of
/// overwriting a scalar quantity, so no concurrent increment or decrement is
/// lost to a last-writer-wins merge.
public struct StockEvent: Hashable, Sendable {
    /// The originating command's id — a retry reuses it, so an identical
    /// replay applies exactly once.
    public let id: UUID
    public let delta: Int64
    public let reason: StockReason
    public let occurredAt: Date

    public init(id: UUID, delta: Int64, reason: StockReason, occurredAt: Date) {
        self.id = id
        self.delta = delta
        self.reason = reason
        self.occurredAt = occurredAt
    }

    /// Structural validity. Content never appears in the failure — only the id
    /// and category are safe to log.
    public var isWellFormed: Bool {
        reason.permits(delta: delta) && occurredAt.timeIntervalSince1970.isFinite
    }
}

/// Content-free integrity findings. Diagnostics may carry opaque ids and a
/// category, never item names or stock values (see the privacy rules in
/// wiki/household-sharing.md → "Privacy and security").
public enum StockIntegrityIssue: Hashable, Sendable {
    /// Same command id, different payloads — one was chosen deterministically.
    case conflictingDuplicate(UUID)
    /// The delta is impossible for its reason, or the instant is not finite.
    case malformedEvent(UUID)
    /// Summing the canonical operations left `Int64`; the item is excluded.
    case quantityOverflow
}

public struct StockProjection: Hashable, Sendable {
    /// What the UI shows: never negative.
    public let quantity: Int64
    /// The true synchronized sum, which two peers consuming the last unit can
    /// drive below zero.
    public let rawQuantity: Int64
    /// An explicit user deletion closes the logical item permanently.
    public let isDeleted: Bool
    /// The item cannot be projected safely and must be withheld from the UI.
    public let isCorrupt: Bool
    public let issues: [StockIntegrityIssue]

    /// Zero is a projection, not a terminal state: a delayed valid operation
    /// can make it positive again (ADR 0010).
    public var isVisible: Bool { !isCorrupt && !isDeleted && quantity > 0 }
}

public enum StockReducer {
    /// Reduces every operation belonging to one logical item — including the
    /// operations of physical members joined by permanent merge claims.
    public static func reduce<S: Sequence>(_ events: S) -> StockProjection
    where S.Element == StockEvent {
        var canonical: [UUID: StockEvent] = [:]
        var issues: Set<StockIntegrityIssue> = []

        for event in events {
            guard event.isWellFormed else {
                issues.insert(.malformedEvent(event.id))
                continue
            }
            guard let rival = canonical[event.id] else {
                canonical[event.id] = event
                continue
            }
            guard rival != event else { continue }  // an identical retry
            issues.insert(.conflictingDuplicate(event.id))
            canonical[event.id] = preferred(rival, event)
        }

        let ordered = canonical.values.sorted { UUIDOrder.isBefore($0.id, $1.id) }
        let isDeleted = ordered.contains { $0.reason == .deleted }

        var raw: Int64 = 0
        for event in ordered {
            let (sum, overflowed) = raw.addingReportingOverflow(event.delta)
            if overflowed {
                issues.insert(.quantityOverflow)
                return StockProjection(quantity: 0, rawQuantity: 0, isDeleted: isDeleted,
                                       isCorrupt: true, issues: sortedIssues(issues))
            }
            raw = sum
        }

        return StockProjection(quantity: max(0, raw), rawQuantity: raw, isDeleted: isDeleted,
                               isCorrupt: false, issues: sortedIssues(issues))
    }

    /// Corrupt data reusing one id with different payloads still has to reduce
    /// to the same answer on every device: take the lexicographically smallest
    /// `(occurredAt, delta, reasonRaw)`.
    private static func preferred(_ lhs: StockEvent, _ rhs: StockEvent) -> StockEvent {
        let left = (lhs.occurredAt.timeIntervalSince1970, lhs.delta, lhs.reason.rawValue)
        let right = (rhs.occurredAt.timeIntervalSince1970, rhs.delta, rhs.reason.rawValue)
        return left <= right ? lhs : rhs
    }

    private static func sortedIssues(_ issues: Set<StockIntegrityIssue>) -> [StockIntegrityIssue] {
        issues.sorted { $0.sortKey < $1.sortKey }
    }
}

extension StockIntegrityIssue {
    /// Stable ordering so two devices report the same diagnostic sequence.
    var sortKey: String {
        switch self {
        case .conflictingDuplicate(let id): "1.\(id.uuidString)"
        case .malformedEvent(let id): "2.\(id.uuidString)"
        case .quantityOverflow: "3"
        }
    }
}
