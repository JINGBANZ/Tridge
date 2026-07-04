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
    var artKey: String = ""
    var categoryRaw: String = FoodCategory.other.rawValue
    var quantity: Int = 1
    var storageRaw: String = StorageLocation.fridge.rawValue
    var purchaseDate: Date = Date()
    var expiryDate: Date = Date()
    var expirySourceRaw: String = ExpirySource.llmEstimate.rawValue
    var statusRaw: String = ItemStatus.active.rawValue
    var consumedDate: Date?
    var store: String?

    init(name: String,
         receiptText: String? = nil,
         artKey: String,
         category: FoodCategory,
         quantity: Int = 1,
         storage: StorageLocation = .fridge,
         purchaseDate: Date = Date(),
         expiryDate: Date,
         expirySource: ExpirySource = .llmEstimate,
         store: String? = nil) {
        self.name = name
        self.receiptText = receiptText
        self.artKey = artKey
        self.categoryRaw = category.rawValue
        self.quantity = quantity
        self.storageRaw = storage.rawValue
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.expirySourceRaw = expirySource.rawValue
        self.store = store
    }

    var category: FoodCategory {
        get { FoodCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
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
