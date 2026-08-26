import CoreData

/// One Household's complete value projection: the logical rows Home renders,
/// every physical root behind them, and the content-free findings for whatever
/// had to be omitted.
///
/// Nothing here is a managed object. The projection is what crosses out of
/// `Persistence` — into `HouseholdSession`, and from there into SwiftUI — so a
/// context-confined object can never reach a view or a background task.
struct HouseholdProjection: Sendable {
    let householdID: UUID
    /// Visible logical items, soonest expiry first.
    let items: [InventoryItemSnapshot]
    /// Every validated physical root, including superseded, zero, and deleted
    /// ones. Purchases are never removed, so this is the complete history the
    /// quick-fill chips and remembered art are ranked from.
    let physicalItems: [PhysicalItemSnapshot]
    /// Exact-name links the projector applied in memory. `DuplicateReconciler`
    /// persists them; the UI never has to flash duplicate rows meanwhile.
    let inferredClaims: [ItemMergeClaim]
    let issues: [RecordIntegrityIssue]
    let stockIssues: [StockIntegrityIssue]

    static func empty(householdID: UUID,
                      issues: [RecordIntegrityIssue] = []) -> HouseholdProjection {
        HouseholdProjection(householdID: householdID, items: [], physicalItems: [],
                            inferredClaims: [], issues: issues, stockIssues: [])
    }
}

/// Maps one Household's records into values and runs the three Linux-testable
/// reducers over them.
///
/// Every rule that decides what a row *means* — the causal frontier, permanent
/// merge claims, immutable stock operations — lives in `Tridge/Core`. This is
/// only the adapter that validates persisted attributes and hands them over. A
/// corrupt record is recorded and skipped: never repaired, never deleted, and
/// never allowed to suppress the rows around it.
enum HouseholdProjector {
    /// Must be called on `household`'s context queue.
    static func project(_ household: HouseholdRecord, today: InventoryDay) -> HouseholdProjection {
        let householdID = household.id ?? HouseholdRecord.unidentifiable
        var issues: [RecordIntegrityIssue] = []

        guard let epochs = try? household.epochReduction() else {
            // Without a readable epoch graph no root can be judged current, and
            // showing every root regardless would resurrect cleared inventory.
            return .empty(householdID: householdID,
                          issues: [RecordIntegrityIssue(entity: .household, id: householdID,
                                                        category: .invalidContext)])
        }

        var physicalItems: [PhysicalItemSnapshot] = []
        var events: [UUID: [StockEvent]] = [:]
        for record in household.items {
            let snapshot: PhysicalItemSnapshot
            do {
                snapshot = try record.snapshot()
            } catch {
                append(error, to: &issues)
                continue
            }
            physicalItems.append(snapshot)

            var operations: [StockEvent] = []
            for change in record.stockChanges {
                do {
                    operations.append(try change.event())
                } catch {
                    append(error, to: &issues)
                }
            }
            events[snapshot.id] = operations
        }

        var claims: [ItemMergeClaimRecord] = []
        for record in household.itemMerges {
            do {
                claims.append(try record.claim())
            } catch {
                append(error, to: &issues)
            }
        }

        let projection = ItemGroupReducer.project(items: physicalItems, claims: claims,
                                                  events: events, epochs: epochs, today: today)

        return HouseholdProjection(
            householdID: householdID,
            items: projection.items,
            physicalItems: physicalItems.sorted { UUIDOrder.isBefore($0.id, $1.id) },
            inferredClaims: projection.inferredClaims,
            issues: (issues + projection.issues)
                .sorted { $0.diagnosticDescription < $1.diagnosticDescription },
            stockIssues: projection.stockIssues)
    }

    private static func append(_ error: Error, to issues: inout [RecordIntegrityIssue]) {
        guard let issue = error as? RecordIntegrityIssue else { return }
        issues.append(issue)
    }
}

extension FridgeItemRecord {
    /// The validated value form of this purchase root.
    ///
    /// Every attribute is optional in the model because CloudKit requires it,
    /// so the rules live in `PhysicalItemSnapshot`'s validating initializer and
    /// stay Linux-testable; this only unwraps what the model cannot.
    func snapshot() throws -> PhysicalItemSnapshot {
        let id = self.id ?? HouseholdRecord.unidentifiable
        guard self.id != nil, let name, let normalizedName, let inventoryEpochContextRaw,
              let artKey, let storageRaw, let expirySourceRaw, let createdAt, let modifiedAt
        else {
            throw RecordIntegrityIssue(entity: .item, id: id, category: .missingValue)
        }
        return try PhysicalItemSnapshot(id: id, name: name, normalizedName: normalizedName,
                                        inventoryEpochContextRaw: inventoryEpochContextRaw,
                                        artKey: artKey, storageRaw: storageRaw,
                                        purchaseDayOrdinal: purchaseDay,
                                        expiryDayOrdinal: expiryDay,
                                        expirySourceRaw: expirySourceRaw,
                                        createdAt: createdAt, modifiedAt: modifiedAt)
    }
}

extension StockChangeRecord {
    /// The validated value form of this immutable operation. A delta its reason
    /// cannot permit is corrupt data, not a surprising quantity.
    func event() throws -> StockEvent {
        let id = self.id ?? HouseholdRecord.unidentifiable
        func corrupt(_ category: RecordIntegrityIssue.Category) -> RecordIntegrityIssue {
            RecordIntegrityIssue(entity: .stockChange, id: id, category: category)
        }

        guard self.id != nil, let reasonRaw, let occurredAt else { throw corrupt(.missingValue) }
        guard let reason = StockReason(rawValue: reasonRaw) else { throw corrupt(.invalidRawValue) }
        let event = StockEvent(id: id, delta: delta, reason: reason, occurredAt: occurredAt)
        guard event.isWellFormed else { throw corrupt(.invalidDelta) }
        return event
    }
}

extension ItemMergeRecord {
    /// The validated value form of this permanent identity claim. Endpoints
    /// stored equal or out of byte order could not have been written by the
    /// reconciler, so they are corrupt rather than repairable.
    func claim() throws -> ItemMergeClaimRecord {
        let id = self.id ?? HouseholdRecord.unidentifiable
        guard self.id != nil, let leftItemID, let rightItemID else {
            throw RecordIntegrityIssue(entity: .itemMerge, id: id, category: .missingValue)
        }
        return try ItemMergeClaimRecord(id: id, leftItemID: leftItemID, rightItemID: rightItemID)
    }
}
