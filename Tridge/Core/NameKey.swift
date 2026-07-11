import Foundation

/// The canonical form of an item name, used for identity (merge matching),
/// search, and remembered-art lookup. Two rows are "the same item" iff their
/// normalized names are equal — storage and art deliberately stay out of the
/// key (see design/item-grouping-search.html).
public enum NameKey {
    /// Case- and diacritic-folded, trimmed, inner whitespace collapsed:
    /// "  Jalapeño  Pepper " → "jalapeno pepper".
    ///
    /// `folding` is used instead of `lowercased()` so non-English case rules
    /// (Turkish I, ß) and accents fold correctly. The locale is pinned: keys
    /// are persisted, so folding must not shift under the user's feet when
    /// the device locale changes.
    public static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
