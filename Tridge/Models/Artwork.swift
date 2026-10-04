import Foundation

/// artKey → item art lookup. artKey stores an ItemID rawValue; v1 renders the
/// id's emoji as text. A custom sprite set can later resolve the same ids to
/// asset-catalog images without touching call sites.
enum Artwork {
    /// Resolves an art key; unrecognized keys fall back to the unknown art, so
    /// a newer build's vocabulary id survives a round trip through an older one.
    static func emoji(forKey key: String) -> String {
        (ItemID(rawValue: key) ?? .unknown).emoji
    }
}
