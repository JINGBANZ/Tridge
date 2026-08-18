import Foundation

/// A permanent, add-only claim that two immutable exact-name identities are the
/// same logical item. Endpoints are distinct and sorted by UUID byte order so
/// every device writes the same pair.
public struct ItemMergeClaim: Hashable, Sendable {
    public let leftItemID: UUID
    public let rightItemID: UUID

    /// Nil for a self-claim, which cannot join anything.
    public init?(_ one: UUID, _ other: UUID) {
        guard one != other else { return nil }
        if UUIDOrder.isBefore(one, other) {
            leftItemID = one
            rightItemID = other
        } else {
            leftItemID = other
            rightItemID = one
        }
    }
}

/// A persisted claim. Duplicate records for the same endpoints are valid and
/// have the same union effect, which is what makes concurrent reconciliation
/// idempotent without a CloudKit-incompatible uniqueness constraint.
public struct ItemMergeClaimRecord: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let claim: ItemMergeClaim

    public init(id: UUID, claim: ItemMergeClaim) {
        self.id = id
        self.claim = claim
    }

    /// Maps one persisted record, rejecting endpoints that are equal or stored
    /// out of byte order.
    public init(id: UUID, leftItemID: UUID, rightItemID: UUID) throws {
        guard let claim = ItemMergeClaim(leftItemID, rightItemID),
              claim.leftItemID == leftItemID, claim.rightItemID == rightItemID
        else {
            throw RecordIntegrityIssue(entity: .itemMerge, id: id, category: .invalidRelationship)
        }
        self.init(id: id, claim: claim)
    }
}

public struct ItemGroupProjection: Hashable, Sendable {
    /// Visible logical items, most urgent first.
    public let items: [InventoryItemSnapshot]
    /// Exact-name links the projector applied in memory and the reconciler
    /// should now persist, so the UI never flashes duplicate rows.
    public let inferredClaims: [ItemMergeClaim]
    public let issues: [RecordIntegrityIssue]
    public let stockIssues: [StockIntegrityIssue]
}

/// Projects physical purchase roots into the logical items Home renders.
///
/// Nothing here transfers stock operations or discards a root: convergence is
/// expressed purely as connected components, so a late operation written by an
/// offline member to any member still counts.
public enum ItemGroupReducer {
    public static func project(items: [PhysicalItemSnapshot],
                               claims: [ItemMergeClaimRecord],
                               events: [UUID: [StockEvent]],
                               epochs: InventoryEpochReduction,
                               today: InventoryDay) -> ItemGroupProjection {
        // A root whose captured frontier has been entirely superseded is not
        // corrupt — Clear All simply retired it.
        let current = items.filter { epochs.supports(context: $0.inventoryContext) }
        // Duplicate ids would only come from corrupt data; keeping the first is
        // deterministic and, unlike `uniqueKeysWithValues`, does not trap.
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var components = ComponentBuilder(ids: current.map(\.id))
        var issues: [RecordIntegrityIssue] = []
        for record in claims {
            let (left, right) = (record.claim.leftItemID, record.claim.rightItemID)
            // An endpoint that has not imported yet, or whose context is
            // superseded, is simply not joinable right now.
            guard let leftItem = byID[left], let rightItem = byID[right] else { continue }
            guard leftItem.normalizedName == rightItem.normalizedName else {
                issues.append(RecordIntegrityIssue(entity: .itemMerge, id: record.id,
                                                   category: .invalidRelationship))
                continue
            }
            components.union(left, right)
        }

        let persisted = groups(components, byID: byID, events: events)
        let inferred = inferredClaims(among: persisted, today: today)
        guard !inferred.isEmpty else {
            return projection(persisted, inferredClaims: [], issues: issues)
        }

        for claim in inferred {
            components.union(claim.leftItemID, claim.rightItemID)
        }
        return projection(groups(components, byID: byID, events: events),
                          inferredClaims: inferred, issues: issues)
    }

    /// One reduced logical item, before it is known whether the UI shows it.
    private struct Group {
        let members: [PhysicalItemSnapshot]   // sorted by id byte order
        let stock: StockProjection

        /// The lowest member id supplies identity and metadata, so peers that
        /// reduce independently choose the same canonical source.
        var canonical: PhysicalItemSnapshot { members[0] }
    }

    private static func groups(_ components: ComponentBuilder,
                               byID: [UUID: PhysicalItemSnapshot],
                               events: [UUID: [StockEvent]]) -> [Group] {
        components.components().compactMap { memberIDs -> Group? in
            let members = UUIDOrder.sorted(memberIDs).compactMap { byID[$0] }
            guard !members.isEmpty else { return nil }
            // Deduplication by event id spans the whole component, so Delete's
            // fan-out marker counts once however many members carry it.
            let operations = members.flatMap { events[$0.id] ?? [] }
            return Group(members: members, stock: StockReducer.reduce(operations))
        }
    }

    /// Exact-name convergence between groups that are each independently
    /// current, active, nonzero, and unexpired.
    private static func inferredClaims(among groups: [Group],
                                       today: InventoryDay) -> [ItemMergeClaim] {
        let eligible = groups.filter {
            $0.stock.isVisible && !$0.canonical.normalizedName.isEmpty
                && !UrgencyRules.isExpired(expiry: $0.canonical.expiryDay, today: today)
        }
        var byName: [String: [UUID]] = [:]
        for group in eligible {
            byName[group.canonical.normalizedName, default: []].append(group.canonical.id)
        }

        var links: [ItemMergeClaim] = []
        for name in byName.keys.sorted() {
            let logicalIDs = UUIDOrder.sorted(byName[name] ?? [])
            guard let lowest = logicalIDs.first, logicalIDs.count > 1 else { continue }
            // A star from the lowest id keeps the claim set small and makes two
            // peers writing concurrently produce the same edges.
            links.append(contentsOf: logicalIDs.dropFirst().compactMap { ItemMergeClaim(lowest, $0) })
        }
        return links
    }

    private static func projection(_ groups: [Group], inferredClaims: [ItemMergeClaim],
                                   issues: [RecordIntegrityIssue]) -> ItemGroupProjection {
        let visible = groups.filter(\.stock.isVisible).map { group -> InventoryItemSnapshot in
            let canonical = group.canonical
            return InventoryItemSnapshot(id: canonical.id,
                                         memberIDs: group.members.map(\.id),
                                         name: canonical.name,
                                         normalizedName: canonical.normalizedName,
                                         quantity: group.stock.quantity,
                                         artKey: canonical.artKey,
                                         storage: canonical.storage,
                                         purchaseDay: canonical.purchaseDay,
                                         expiryDay: canonical.expiryDay,
                                         expirySource: canonical.expirySource)
        }
        // Groups reduce in dictionary order, so the concatenation has to be
        // re-sorted to keep the diagnostic sequence identical across devices.
        let stockIssues = Set(groups.flatMap(\.stock.issues)).sorted { $0.sortKey < $1.sortKey }
        return ItemGroupProjection(
            items: visible.sorted {
                $0.expiryDay == $1.expiryDay ? UUIDOrder.isBefore($0.id, $1.id)
                                             : $0.expiryDay < $1.expiryDay
            },
            inferredClaims: inferredClaims,
            issues: issues.sorted { $0.diagnosticDescription < $1.diagnosticDescription },
            stockIssues: stockIssues)
    }
}

/// Union-find over physical item ids. Claim order and duplicate claims cannot
/// change the components it produces.
private struct ComponentBuilder {
    private var parent: [UUID: UUID]

    init(ids: [UUID]) {
        parent = Dictionary(ids.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func union(_ one: UUID, _ other: UUID) {
        guard let left = root(one), let right = root(other), left != right else { return }
        // Attach to the lower id so the representative is stable regardless of
        // the order the claims arrived in.
        if UUIDOrder.isBefore(left, right) {
            parent[right] = left
        } else {
            parent[left] = right
        }
    }

    func components() -> [[UUID]] {
        var members: [UUID: [UUID]] = [:]
        for id in parent.keys {
            guard let representative = root(id) else { continue }
            members[representative, default: []].append(id)
        }
        return Array(members.values)
    }

    private func root(_ id: UUID) -> UUID? {
        var current = id
        while let next = parent[current], next != current {
            current = next
        }
        return parent[current] == nil ? nil : current
    }
}
