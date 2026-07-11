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
}
