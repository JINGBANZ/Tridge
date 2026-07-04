import Foundation

/// artKey → item art lookup. v1 stores the emoji itself as the key and renders
/// it as text; a custom sprite set can later resolve the same keys to images in
/// the asset catalog without touching call sites.
enum Artwork {
    /// Resolves an item's art, falling back to its category default.
    static func artwork(for item: FridgeItem) -> String {
        resolve(key: item.artKey, category: item.category)
    }

    static func resolve(key: String, category: FoodCategory) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? category.defaultEmoji : trimmed
    }

    /// The prebuilt set offered by the ArtPicker.
    static let all: [String] = [
        "🥬", "🥦", "🥕", "🌽", "🥒", "🍅", "🥑", "🫑", "🥔", "🧅", "🧄", "🍄",
        "🍎", "🍌", "🍇", "🍓", "🫐", "🍊", "🍋", "🍑", "🍐", "🍉", "🍍", "🥝",
        "🥛", "🧀", "🧈", "🥚", "🥣", "🍦",
        "🍗", "🥩", "🥓", "🌭", "🍖",
        "🐟", "🦐", "🦀", "🦪",
        "🍞", "🥐", "🥯", "🧇", "🥞", "🍰",
        "🧃", "🥤", "🍷", "🍺", "☕️", "🫖",
        "🍝", "🍕", "🌮", "🥪", "🍱", "🥡",
        "🥫", "🍚", "🍜", "🧂", "🍯", "🫙", "🥜", "🍫", "🍪",
        "🧊", "🛒",
    ]
}
