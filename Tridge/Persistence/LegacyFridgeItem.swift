import Foundation
import SwiftData

/// The shipping build's inventory row, kept only so the archived pre-sharing
/// store can still be read.
///
/// This is the *whole* remaining surface of the old SwiftData schema: nothing
/// but `LegacyInventoryArchive` may reference it, and the archive reader never
/// saves through it. Its stored properties and index are deliberately
/// unchanged — the schema has to keep matching the store on disk, so this type
/// is frozen rather than tidied. Derived helpers the old UI used are gone; the
/// reader maps a row into `LegacyInventoryRow` and everything downstream works
/// on that value.
@Model
final class FridgeItem {
    #Index<FridgeItem>([\.normalizedName])

    var id: UUID = UUID()
    var name: String = ""
    /// `NameKey.normalize(name)` — the shipping build's identity key.
    var normalizedName: String = ""
    /// Never read by the migration: raw receipt text stays in the archive and
    /// is only removed by the user's explicit Erase Old Local Inventory.
    var receiptText: String?
    /// An ItemID rawValue.
    var artKey: String = ItemID.unknown.rawValue
    var quantity: Int = 1
    var storageRaw: String = StorageLocation.fridge.rawValue
    var purchaseDate: Date = Date()
    var expiryDate: Date = Date()
    var expirySourceRaw: String = ExpirySource.llmEstimate.rawValue
    var statusRaw: String = ItemStatus.active.rawValue
    var consumedDate: Date?

    init(name: String,
         receiptText: String? = nil,
         artKey: String,
         quantity: Int = 1,
         storage: StorageLocation = .fridge,
         purchaseDate: Date = Date(),
         expiryDate: Date,
         expirySource: ExpirySource = .llmEstimate) {
        self.name = name
        self.normalizedName = NameKey.normalize(name)
        self.receiptText = receiptText
        self.artKey = artKey
        self.quantity = quantity
        self.storageRaw = storage.rawValue
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.expirySourceRaw = expirySource.rawValue
    }

    /// Only eaten and tossed rows are left behind; active rows migrate.
    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
}
