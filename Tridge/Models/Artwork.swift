import Foundation

/// artKey → item art lookup. artKey stores an ItemID rawValue; v1 renders the
/// id's emoji as text. A custom sprite set can later resolve the same ids to
/// asset-catalog images without touching call sites.
enum Artwork {
    /// Resolves an item's art; unrecognized keys fall back to the unknown art.
    static func artwork(for item: FridgeItem) -> String {
        emoji(forKey: item.artKey)
    }

    static func emoji(forKey key: String) -> String {
        (ItemID(rawValue: key) ?? .unknown).emoji
    }
}
