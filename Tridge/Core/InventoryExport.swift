import Foundation

/// One Household's complete inventory history, as a portable document.
///
/// This is the honest export the data-rights section promises: the rows Home
/// shows *and* everything behind them — every physical purchase root, every
/// immutable stock operation including zero, deleted, and superseded-context
/// ones, every permanent merge claim, and the whole causal clear graph. A user
/// who exports and then deletes has really taken their data with them.
///
/// What it deliberately never carries is anything that is not theirs to take or
/// not theirs alone: no member or share metadata, no participant identity, no
/// account identifier, no invitation, no diagnostics, and no receipt text or
/// image. Receipt text is not even persisted — it lives in the review draft and
/// is discarded at confirmation — so its absence here is structural.
public struct InventoryExportDocument: Codable, Equatable, Sendable {
    /// Bumped only for a change a reader could not otherwise cope with.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let householdName: String
    /// The rows Home was showing, as projected.
    public let items: [LogicalItem]
    /// Every validated physical root, current or not.
    public let physicalItems: [PhysicalItem]
    /// Every immutable operation, across every root.
    public let stockOperations: [StockOperation]
    /// Every permanent exact-name identity claim.
    public let itemMerges: [MergeClaim]
    /// The complete causal clear graph.
    public let clearEvents: [ClearEvent]

    public init(exportedAt: Date, householdName: String, items: [LogicalItem],
                physicalItems: [PhysicalItem], stockOperations: [StockOperation],
                itemMerges: [MergeClaim], clearEvents: [ClearEvent]) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.householdName = householdName
        self.items = items
        self.physicalItems = physicalItems
        self.stockOperations = stockOperations
        self.itemMerges = itemMerges
        self.clearEvents = clearEvents
    }

    public struct LogicalItem: Codable, Equatable, Sendable {
        public let id: UUID
        public let memberIDs: [UUID]
        public let name: String
        public let quantity: Int64
        public let artKey: String
        public let storage: String
        public let purchaseDay: InventoryDay
        public let expiryDay: InventoryDay
        public let expirySource: String

        public init(_ item: InventoryItemSnapshot) {
            id = item.id
            memberIDs = item.memberIDs
            name = item.name
            quantity = item.quantity
            artKey = item.artKey
            storage = item.storage.rawValue
            purchaseDay = item.purchaseDay
            expiryDay = item.expiryDay
            expirySource = item.expirySource.rawValue
        }
    }

    public struct PhysicalItem: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let normalizedName: String
        /// The frontier this root captured when it was created. Superseded
        /// contexts are exported too — that history is what makes an export
        /// complete rather than merely current.
        public let inventoryContext: [UUID]
        public let artKey: String
        public let storage: String
        public let purchaseDay: InventoryDay
        public let expiryDay: InventoryDay
        public let expirySource: String
        public let createdAt: Date
        public let modifiedAt: Date

        public init(_ item: PhysicalItemSnapshot) {
            id = item.id
            name = item.name
            normalizedName = item.normalizedName
            inventoryContext = UUIDOrder.sorted(item.inventoryContext)
            artKey = item.artKey
            storage = item.storage.rawValue
            purchaseDay = item.purchaseDay
            expiryDay = item.expiryDay
            expirySource = item.expirySource.rawValue
            createdAt = item.createdAt
            modifiedAt = item.modifiedAt
        }
    }

    public struct StockOperation: Codable, Equatable, Sendable {
        public let id: UUID
        public let itemID: UUID
        public let delta: Int64
        public let reason: String
        public let occurredAt: Date

        public init(_ event: StockEvent, itemID: UUID) {
            id = event.id
            self.itemID = itemID
            delta = event.delta
            reason = event.reason.rawValue
            occurredAt = event.occurredAt
        }
    }

    public struct MergeClaim: Codable, Equatable, Sendable {
        public let id: UUID
        public let leftItemID: UUID
        public let rightItemID: UUID

        public init(_ record: ItemMergeClaimRecord) {
            id = record.id
            leftItemID = record.claim.leftItemID
            rightItemID = record.claim.rightItemID
        }
    }

    public struct ClearEvent: Codable, Equatable, Sendable {
        public let id: UUID
        public let epochID: UUID
        public let parentEpochIDs: [UUID]
        public let revision: Int64
        public let occurredAt: Date

        public init(_ event: HouseholdClearEvent) {
            id = event.id
            epochID = event.epochID
            parentEpochIDs = UUIDOrder.sorted(event.parentEpochIDs)
            revision = event.revision
            occurredAt = event.occurredAt
        }
    }

    /// A stable, readable encoding: sorted keys so two exports of the same
    /// fridge diff cleanly, and ISO-8601 dates so a reader needs no Apple
    /// framework to make sense of them.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> InventoryExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InventoryExportDocument.self, from: data)
    }

    /// A file name that names the fridge without leaking anything else. Every
    /// character that could change what a path means is replaced.
    public var suggestedFileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe = householdName.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespaces)
        let name = safe.isEmpty ? "Fridge" : safe
        return "\(name) Inventory.json"
    }
}
