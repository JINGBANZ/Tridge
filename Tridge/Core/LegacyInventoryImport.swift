import Foundation

/// One active row read out of the archived pre-sharing SwiftData store.
///
/// A dedicated one-time reader opens that archive read-only; this value type is
/// the only shape the legacy schema takes anywhere else, which keeps SwiftData
/// out of the sharing stack entirely. Receipt text is deliberately absent: it
/// stays in the retained local archive and is never copied into a Household
/// store (wiki/household-sharing.md → "Upgrade from the shipping build").
public struct LegacyInventoryRow: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let artKey: String
    public let quantity: Int
    public let storageRaw: String
    /// The instants the shipping build stored and displayed. They become civil
    /// days here, in one captured time zone.
    public let purchaseDate: Date
    public let expiryDate: Date
    public let expirySourceRaw: String

    public init(id: UUID, name: String, artKey: String, quantity: Int, storageRaw: String,
                purchaseDate: Date, expiryDate: Date, expirySourceRaw: String) {
        self.id = id
        self.name = name
        self.artKey = artKey
        self.quantity = quantity
        self.storageRaw = storageRaw
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.expirySourceRaw = expirySourceRaw
    }
}

/// Turns the archived active rows into the purchases they become in a Household.
public enum LegacyInventoryPlanner {
    /// Plans the complete archive, or throws for the first row that cannot be
    /// represented.
    ///
    /// Planning the whole set before anything is written is what makes a corrupt
    /// row fail the migration instead of writing a partial inventory. One
    /// captured calendar converts every row, so a migration running across local
    /// midnight cannot land two rows of one archive on different days.
    ///
    /// Rows are not grouped by name: each keeps its own root and metadata, and
    /// exact-name convergence is `DuplicateReconciler`'s job afterwards, so the
    /// migration itself stays lossless (ADR 0008).
    public static func plan(_ rows: [LegacyInventoryRow],
                            calendar: Calendar) throws -> [PurchaseDraft] {
        var seen: Set<UUID> = []
        return try rows.map { row in
            guard seen.insert(row.id).inserted else {
                throw RecordIntegrityIssue(entity: .item, id: row.id, category: .duplicateIdentity)
            }
            return try draft(for: row, calendar: calendar)
        }
    }

    private static func draft(for row: LegacyInventoryRow,
                              calendar: Calendar) throws -> PurchaseDraft {
        func corrupt(_ category: RecordIntegrityIssue.Category) -> RecordIntegrityIssue {
            RecordIntegrityIssue(entity: .item, id: row.id, category: category)
        }

        guard !NameKey.normalize(row.name).isEmpty else { throw corrupt(.invalidName) }
        // The shipping build flips status to eaten/tossed at the last unit, so
        // an active row can only carry a positive quantity.
        guard let quantity = Int64(exactly: row.quantity), quantity > 0 else {
            throw corrupt(.invalidDelta)
        }
        // An unrepresentable raw value is rejected rather than replaced with a
        // default: the new stores validate the same vocabulary, so a substituted
        // value would silently rewrite data the user can still see in the
        // retained archive. No shipped build can write one.
        guard let storage = StorageLocation(rawValue: row.storageRaw),
              let expirySource = ExpirySource(rawValue: row.expirySourceRaw)
        else { throw corrupt(.invalidRawValue) }
        // Before the conversion: calendar components of a non-finite instant
        // are meaningless rather than out of range.
        guard row.purchaseDate.timeIntervalSince1970.isFinite,
              row.expiryDate.timeIntervalSince1970.isFinite
        else { throw corrupt(.invalidInstant) }
        // A purchase day was stamped with `Date()`, so one outside the range is
        // corrupt. An expiry day was derived from an unbounded model-guessed
        // shelf life with no clamp in the shipping build, so one past the range
        // is a hallucinated number rather than a broken row: clamp it the way
        // `PurchaseDraft(reviewing:)` clamps the same input today. Failing it
        // would leave that installation unable to migrate anything, ever.
        guard let purchaseDay = InventoryDay(date: row.purchaseDate, calendar: calendar),
              let expiryDay = representableExpiryDay(row.expiryDate, calendar: calendar)
        else { throw corrupt(.invalidDay) }

        // The legacy id becomes both the root id and the acquisition's command
        // id, so a retry recognizes the row it already wrote. The purchase
        // instant is the event's `occurredAt` for the same reason: a replan must
        // produce a byte-identical event, never `Date()`.
        return PurchaseDraft(itemID: row.id, stockChangeID: row.id, name: row.name,
                             quantity: quantity, artKey: row.artKey, storage: storage,
                             purchaseDay: purchaseDay, expiryDay: expiryDay,
                             expirySource: expirySource, explicitMetadataFields: [],
                             occurredAt: row.purchaseDate)
    }

    /// The expiry day, or the last supported one for a date beyond it. Nil for a
    /// date before the supported range, which no shipping path can produce.
    private static func representableExpiryDay(_ date: Date,
                                               calendar: Calendar) -> InventoryDay? {
        if let day = InventoryDay(date: date, calendar: calendar) { return day }
        guard let latest = InventoryDay.latest.startOfDay(in: calendar), date > latest else {
            return nil
        }
        return .latest
    }
}
