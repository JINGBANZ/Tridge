import Foundation

/// A content-free integrity finding about one persisted record.
///
/// Corrupt imported data is excluded from the UI and left intact for
/// diagnostics; the finding may carry the entity, its opaque id, and a
/// category, never a household or item name (see wiki/household-sharing.md →
/// "Privacy and security").
public struct RecordIntegrityIssue: Error, Hashable, Sendable {
    public enum Entity: String, Sendable {
        case household, item, stockChange, itemMerge, householdClear
    }

    public enum Category: String, Sendable {
        case missingValue, invalidRawValue, invalidName, invalidDay, invalidContext
        case invalidInstant, invalidDelta, invalidRelationship
        /// Two records claim one id, so neither can be written under it.
        case duplicateIdentity
    }

    public let entity: Entity
    public let id: UUID
    public let category: Category

    public init(entity: Entity, id: UUID, category: Category) {
        self.entity = entity
        self.id = id
        self.category = category
    }

    public var diagnosticDescription: String {
        "\(entity.rawValue) \(id.uuidString) \(category.rawValue)"
    }
}

/// Whether a household lives in this account's private store or arrived through
/// someone else's share. Derived from the persistent store, never from an
/// optional participant field.
public enum HouseholdOwnership: String, Hashable, Sendable {
    case owned, received
}

public struct HouseholdSnapshot: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let ownership: HouseholdOwnership
    public let createdAt: Date
    /// Whether a `CKShare` currently exists for this household.
    public let isShared: Bool

    public init(id: UUID, name: String, ownership: HouseholdOwnership, createdAt: Date,
                isShared: Bool) {
        self.id = id
        self.name = name
        self.ownership = ownership
        self.createdAt = createdAt
        self.isShared = isShared
    }
}

/// One physical purchase root — the durable anchor a purchase's operation
/// history hangs from. Several of these can project as one logical item.
public struct PhysicalItemSnapshot: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let normalizedName: String
    /// The complete Household frontier visible when this root was created.
    public let inventoryContext: Set<UUID>
    /// An `ItemID` raw value. Kept as text so a newer build's vocabulary id
    /// survives a round trip through an older one.
    public let artKey: String
    public let storage: StorageLocation
    public let purchaseDay: InventoryDay
    public let expiryDay: InventoryDay
    public let expirySource: ExpirySource
    public let createdAt: Date
    public let modifiedAt: Date

    public init(id: UUID, name: String, inventoryContext: Set<UUID>, artKey: String,
                storage: StorageLocation, purchaseDay: InventoryDay, expiryDay: InventoryDay,
                expirySource: ExpirySource, createdAt: Date, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.normalizedName = NameKey.normalize(name)
        self.inventoryContext = inventoryContext
        self.artKey = artKey
        self.storage = storage
        self.purchaseDay = purchaseDay
        self.expiryDay = expiryDay
        self.expirySource = expirySource
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Maps one persisted record's raw attributes, rejecting corrupt data before
    /// it can reach a snapshot. The persistence layer supplies raw values; every
    /// rule lives here so it stays Linux-testable.
    public init(id: UUID, name: String, normalizedName: String, inventoryEpochContextRaw: String,
                artKey: String, storageRaw: String, purchaseDayOrdinal: Int32,
                expiryDayOrdinal: Int32, expirySourceRaw: String, createdAt: Date,
                modifiedAt: Date) throws {
        func corrupt(_ category: RecordIntegrityIssue.Category) -> RecordIntegrityIssue {
            RecordIntegrityIssue(entity: .item, id: id, category: category)
        }

        let key = NameKey.normalize(name)
        guard !key.isEmpty, key == normalizedName else { throw corrupt(.invalidName) }
        guard let storage = StorageLocation(rawValue: storageRaw),
              let expirySource = ExpirySource(rawValue: expirySourceRaw)
        else { throw corrupt(.invalidRawValue) }
        guard let purchaseDay = InventoryDay(ordinal: purchaseDayOrdinal),
              let expiryDay = InventoryDay(ordinal: expiryDayOrdinal)
        else { throw corrupt(.invalidDay) }
        guard let context = InventoryEpochCodec.decode(inventoryEpochContextRaw) else {
            throw corrupt(.invalidContext)
        }
        guard createdAt.timeIntervalSince1970.isFinite, modifiedAt.timeIntervalSince1970.isFinite
        else { throw corrupt(.invalidInstant) }

        self.init(id: id, name: name, inventoryContext: context, artKey: artKey,
                  storage: storage, purchaseDay: purchaseDay, expiryDay: expiryDay,
                  expirySource: expirySource, createdAt: createdAt, modifiedAt: modifiedAt)
    }

    /// Unrecognized keys resolve to the fallback art without losing the stored id.
    public var artID: ItemID { ItemID(rawValue: artKey) ?? .unknown }
    public var foodCategory: FoodCategory { artID.foodCategory }
}

/// One row of Home: the projection of every physical member joined by permanent
/// merge claims. Carries no receipt text — that exists only in the in-memory
/// review draft and is discarded at confirmation.
public struct InventoryItemSnapshot: Hashable, Sendable, Identifiable {
    /// The lowest member id by byte order, so every device agrees on identity.
    public let id: UUID
    /// Every physical member, sorted by byte order. Commands may address any of
    /// them; the repository resolves the current component.
    public let memberIDs: [UUID]
    public let name: String
    public let normalizedName: String
    public let quantity: Int64
    public let artKey: String
    public let storage: StorageLocation
    public let purchaseDay: InventoryDay
    public let expiryDay: InventoryDay
    public let expirySource: ExpirySource

    public init(id: UUID, memberIDs: [UUID], name: String, normalizedName: String,
                quantity: Int64, artKey: String, storage: StorageLocation,
                purchaseDay: InventoryDay, expiryDay: InventoryDay, expirySource: ExpirySource) {
        self.id = id
        self.memberIDs = memberIDs
        self.name = name
        self.normalizedName = normalizedName
        self.quantity = quantity
        self.artKey = artKey
        self.storage = storage
        self.purchaseDay = purchaseDay
        self.expiryDay = expiryDay
        self.expirySource = expirySource
    }

    public var artID: ItemID { ItemID(rawValue: artKey) ?? .unknown }
    public var foodCategory: FoodCategory { artID.foodCategory }

    public func daysLeft(from today: InventoryDay) -> Int {
        UrgencyRules.daysLeft(until: expiryDay, from: today)
    }

    public func urgency(on today: InventoryDay) -> Urgency {
        UrgencyRules.urgency(daysLeft: daysLeft(from: today))
    }

    public func isExpired(on today: InventoryDay) -> Bool {
        UrgencyRules.isExpired(expiry: expiryDay, today: today)
    }
}
