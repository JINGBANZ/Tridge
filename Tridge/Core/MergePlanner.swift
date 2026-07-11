import Foundation

/// Value snapshot of an active inventory row. `FridgeItem` (SwiftData) is not
/// part of this package, so the planner works on plain values and stays
/// Linux-testable.
public struct MergeCandidate: Sendable {
    public let id: UUID
    public let normalizedName: String
    public let quantity: Int
    public let isExpired: Bool
    public let purchaseDate: Date

    public init(id: UUID, normalizedName: String, quantity: Int,
                isExpired: Bool, purchaseDate: Date) {
        self.id = id
        self.normalizedName = normalizedName
        self.quantity = quantity
        self.isExpired = isExpired
        self.purchaseDate = purchaseDate
    }
}

public enum MergeDecision: Equatable, Sendable {
    case insert
    case merge(into: UUID, resultingQuantity: Int)
}

/// Where a planned row lands when several rows save together.
public enum PlannedTarget: Equatable, Sendable {
    /// An item already in the fridge.
    case existing(UUID)
    /// The item created by an earlier row of this same save (by row index) —
    /// review-time renames can make two rows collide.
    case insertedRow(Int)
}

public enum RowPlan: Equatable, Sendable {
    case insert
    case merge(PlannedTarget, resultingQuantity: Int)
}

/// Decides whether a row being saved groups into an existing active item
/// (issue #26). Exact normalized-name match only — a false merge silently
/// absorbing a distinct item is worse than a duplicate, so fuzzy signals are
/// reserved for suggestion UI where a human confirms.
public enum MergePlanner {
    /// Quantities are a count clamped to the UI's 1...99 bounds everywhere.
    public static let maxQuantity = 99

    /// Expired items never absorb a new purchase: a fresh buy of something
    /// already past its date is a new batch and inserts as its own row.
    /// Among several matches the most recent purchase wins.
    public static func decide(name: String, quantity: Int,
                              existing: [MergeCandidate]) -> MergeDecision {
        let key = NameKey.normalize(name)
        guard !key.isEmpty,
              let match = existing
                  .filter({ $0.normalizedName == key && !$0.isExpired })
                  .max(by: { $0.purchaseDate < $1.purchaseDate })
        else { return .insert }
        return .merge(into: match.id,
                      resultingQuantity: min(match.quantity + quantity, maxQuantity))
    }

    /// Plans a whole multi-row save (the scan confirm): each row either
    /// merges into an existing active item, merges into an earlier row of
    /// this save whose name it duplicates, or inserts. Quantities accumulate
    /// row over row, so two rows landing on the same target stack instead of
    /// clobbering each other.
    public static func plan(rows: [(name: String, quantity: Int)],
                            existing: [MergeCandidate]) -> [RowPlan] {
        var candidates = existing
        var insertedIndexByKey: [String: Int] = [:]
        var insertedQuantity: [Int: Int] = [:]
        var plans: [RowPlan] = []

        for (index, row) in rows.enumerated() {
            switch decide(name: row.name, quantity: row.quantity, existing: candidates) {
            case .merge(let id, let resultingQuantity):
                plans.append(.merge(.existing(id), resultingQuantity: resultingQuantity))
                if let i = candidates.firstIndex(where: { $0.id == id }) {
                    candidates[i] = MergeCandidate(id: id,
                                                   normalizedName: candidates[i].normalizedName,
                                                   quantity: resultingQuantity,
                                                   isExpired: candidates[i].isExpired,
                                                   purchaseDate: candidates[i].purchaseDate)
                }
            case .insert:
                let key = NameKey.normalize(row.name)
                if !key.isEmpty, let earlier = insertedIndexByKey[key] {
                    let quantity = min((insertedQuantity[earlier] ?? 1) + row.quantity,
                                       maxQuantity)
                    insertedQuantity[earlier] = quantity
                    plans.append(.merge(.insertedRow(earlier), resultingQuantity: quantity))
                } else {
                    insertedIndexByKey[key] = index
                    insertedQuantity[index] = row.quantity
                    plans.append(.insert)
                }
            }
        }
        return plans
    }
}
