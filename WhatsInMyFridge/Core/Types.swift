import Foundation

/// Item category, mirroring the LLM contract's category vocabulary.
public enum FoodCategory: String, Codable, CaseIterable, Sendable {
    case produce, dairy, meat, seafood, frozen, pantry, beverage, bakery, deli,
         leftovers, condiment, other

    /// Fallback emoji when an item has no usable artKey of its own.
    public var defaultEmoji: String {
        switch self {
        case .produce: "🥬"
        case .dairy: "🥛"
        case .meat: "🍗"
        case .seafood: "🐟"
        case .frozen: "🧊"
        case .pantry: "🥫"
        case .beverage: "🧃"
        case .bakery: "🍞"
        case .deli: "🥪"
        case .leftovers: "🍝"
        case .condiment: "🧂"
        case .other: "🛒"
        }
    }
}

public enum StorageLocation: String, Codable, CaseIterable, Sendable {
    case fridge, freezer, pantry

    public var label: String {
        switch self {
        case .fridge: "Fridge"
        case .freezer: "Freezer"
        case .pantry: "Pantry"
        }
    }
}

public enum ExpirySource: String, Codable, Sendable {
    case llmEstimate, userSet, scannedLabel
}

public enum ItemStatus: String, Codable, Sendable {
    case active, eaten, tossed
}

public enum Confidence: String, Codable, Sendable {
    case high, low
}
