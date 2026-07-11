import Foundation
import SwiftData

/// One fridge inventory entry (see spec → "SwiftData schema").
/// Enums persist as raw strings and every property has a default so the schema
/// stays CloudKit-compatible; urgency is computed, never stored.
@Model
final class FridgeItem {
    #Index<FridgeItem>([\.normalizedName])

    var id: UUID = UUID()
    var name: String = ""
    /// `NameKey.normalize(name)` — the identity key for merge matching and
    /// search. Kept in lockstep with `name` via `setName`; never shown.
    var normalizedName: String = ""
    var receiptText: String?
    /// An ItemID rawValue; resolved to art via `Artwork`.
    var artKey: String = ItemID.unknown.rawValue
    var quantity: Int = 1
    var storageRaw: String = StorageLocation.fridge.rawValue
    /// The day the receipt was scanned — not read off the receipt.
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

    /// The only sanctioned way to rename: keeps `normalizedName` in lockstep.
    func setName(_ newName: String) {
        name = newName
        normalizedName = NameKey.normalize(newName)
    }

    var storage: StorageLocation {
        get { StorageLocation(rawValue: storageRaw) ?? .fridge }
        set { storageRaw = newValue.rawValue }
    }

    /// Derived from the art's ItemID, never stored — changing the art is how
    /// the user recategorizes an item.
    var foodCategory: FoodCategory {
        (ItemID(rawValue: artKey) ?? .unknown).foodCategory
    }

    var expirySource: ExpirySource {
        get { ExpirySource(rawValue: expirySourceRaw) ?? .llmEstimate }
        set { expirySourceRaw = newValue.rawValue }
    }

    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var daysLeft: Int {
        UrgencyRules.daysLeft(until: expiryDate)
    }

    var urgency: Urgency {
        UrgencyRules.urgency(daysLeft: daysLeft)
    }

    var isExpired: Bool {
        UrgencyRules.isExpired(expiry: expiryDate)
    }

    var pillLabel: String {
        UrgencyRules.pillLabel(daysLeft: daysLeft)
    }

    /// Value snapshot handed to the Linux-testable `MergePlanner`.
    var mergeCandidate: MergeCandidate {
        MergeCandidate(id: id, normalizedName: normalizedName, quantity: quantity,
                       isExpired: isExpired, purchaseDate: purchaseDate)
    }
}
