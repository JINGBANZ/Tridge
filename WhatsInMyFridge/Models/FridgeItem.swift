import Foundation
import SwiftData

/// One fridge inventory entry (see spec → "SwiftData schema").
/// Enums persist as raw strings and every property has a default so the schema
/// stays CloudKit-compatible; urgency is computed, never stored.
@Model
final class FridgeItem {
    var id: UUID = UUID()
    var name: String = ""
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
        self.receiptText = receiptText
        self.artKey = artKey
        self.quantity = quantity
        self.storageRaw = storage.rawValue
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.expirySourceRaw = expirySource.rawValue
    }

    var storage: StorageLocation {
        get { StorageLocation(rawValue: storageRaw) ?? .fridge }
        set { storageRaw = newValue.rawValue }
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
}
