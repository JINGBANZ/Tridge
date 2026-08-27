import CoreData

/// What one processed history batch has to bring up to date before its token
/// may advance.
///
/// Closures rather than a protocol because the two effects live on different
/// isolation domains — reconciliation on a background writer, the session
/// refresh on the main actor — and the processor should not have to know that.
struct HistoryEffects: Sendable {
    /// Persists the exact-name claims an import made possible. The projector
    /// already applies the same union in memory, so this only makes it durable.
    let reconcileDuplicates: @Sendable (UUID) async throws -> Void
    /// Rebuilds the visible snapshots, reminders, and badge.
    let refreshSession: @Sendable (Set<UUID>) async -> Void
}

/// Consumes one persistent-history stream per store.
///
/// The order is the contract's: fetch after this store's token, merge the
/// object-id changes into the view context, run duplicate reconciliation for
/// every affected Household, refresh the session and its local effects, and
/// only then archive the new token. An interrupted pass therefore repeats
/// rather than skipping a batch.
///
/// It is an actor so the two stores' passes cannot interleave — a remote-change
/// notification can arrive for either store at any moment, and reconciliation
/// writes.
actor PersistentHistoryProcessor {
    /// Transaction authors this app writes itself. They are filtered out of the
    /// *results* but still advance the token: leaving them unconsumed would make
    /// every later pass rescan them forever.
    static let appAuthors = ["app.inventory", "app.reconcile"]

    private let persistence: PersistenceController
    private let tokens: HistoryTokenStore
    private let effects: HistoryEffects

    init(persistence: PersistenceController, tokens: HistoryTokenStore, effects: HistoryEffects) {
        self.persistence = persistence
        self.tokens = tokens
        self.effects = effects
    }

    /// Processes both stores — the shape used at activation and on a
    /// foreground refresh, where either store may have imported.
    func processAll() async {
        for store in [persistence.privateStore, persistence.sharedStore] {
            await process(store)
        }
    }

    /// Processes the store a remote-change notification named, or both when the
    /// notification does not identify one.
    func process(storeURL: URL?) async {
        guard let storeURL,
              let store = [persistence.privateStore, persistence.sharedStore]
                  .first(where: { $0.url == storeURL })
        else {
            await processAll()
            return
        }
        await process(store)
    }

    private func process(_ store: NSPersistentStore) async {
        let identifier = store.identifier
        do {
            guard let batch = try await fetchBatch(store) else { return }

            if !batch.householdIDs.isEmpty {
                // Reconciliation before the token advances: a claim this import
                // made possible has to be durable, or an interrupted pass would
                // leave the projector inferring it forever.
                for householdID in UUIDOrder.sorted(batch.householdIDs) {
                    try await effects.reconcileDuplicates(householdID)
                }
                await effects.refreshSession(batch.householdIDs)
            }
            // Last, so an interrupted pass repeats rather than skipping a batch.
            tokens.save(batch.token, forStoreIdentifier: identifier)
        } catch {
            // The token stays where it was, so the same batch is retried on the
            // next notification. Content-free: a domain and a code.
            let details = error as NSError
            AppLog.household.error(
                "History pass failed: history.\(details.domain).\(details.code)")
        }
    }

    /// One store's unprocessed transactions, merged into the view context.
    private struct Batch {
        let token: NSPersistentHistoryToken
        /// Households whose graph the batch touched, as far as the changes can
        /// be resolved. A deletion cannot name its Household, so a batch that
        /// contains one reports every accessible Household instead.
        let householdIDs: Set<UUID>
    }

    private func fetchBatch(_ store: NSPersistentStore) async throws -> Batch? {
        let after = tokens.token(forStoreIdentifier: store.identifier)
        let context = persistence.newReaderContext()
        let persistence = self.persistence

        return try await context.perform {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: after)
            // Scoped to one store: the two streams are independent, and a
            // transaction from the other store must not advance this token.
            request.affectedStores = [store]
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  let newest = transactions.last?.token
            else { return nil }

            // Filtered from the results, not from the fetch: this app's own
            // saves are already in the view context, but the token still has to
            // move past them.
            let remote = transactions.filter { !Self.appAuthors.contains($0.author ?? "") }
            guard !remote.isEmpty else {
                return Batch(token: newest, householdIDs: [])
            }

            let viewContext = persistence.viewContext
            var changedIDs: [NSManagedObjectID] = []
            var hasUnresolvableChange = false
            for transaction in remote {
                viewContext.perform {
                    viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
                }
                for change in transaction.changes ?? [] {
                    if change.changeType == .delete {
                        hasUnresolvableChange = true
                    } else {
                        changedIDs.append(change.changedObjectID)
                    }
                }
            }

            let resolved = Self.households(of: changedIDs, in: context)
            guard hasUnresolvableChange else {
                return Batch(token: newest, householdIDs: resolved)
            }
            // A deleted object cannot be asked which Household it belonged to,
            // so the batch covers every Household in this store rather than
            // guessing — reconciliation and refresh are both idempotent.
            return Batch(token: newest,
                         householdIDs: resolved.union(Self.allHouseholds(in: store,
                                                                         context: context)))
        }
    }

    /// Maps changed objects to the Households they belong to. A record that no
    /// longer resolves is simply not attributable and is skipped.
    private static func households(of objectIDs: [NSManagedObjectID],
                                   in context: NSManagedObjectContext) -> Set<UUID> {
        var ids: Set<UUID> = []
        for objectID in objectIDs {
            guard let object = try? context.existingObject(with: objectID) else { continue }
            switch object {
            case let household as HouseholdRecord:
                household.id.map { ids.insert($0) }
            case let item as FridgeItemRecord:
                item.household?.id.map { ids.insert($0) }
            case let change as StockChangeRecord:
                change.item?.household?.id.map { ids.insert($0) }
            case let merge as ItemMergeRecord:
                merge.household?.id.map { ids.insert($0) }
            case let clear as HouseholdClearRecord:
                clear.household?.id.map { ids.insert($0) }
            default:
                continue
            }
        }
        return ids
    }

    private static func allHouseholds(in store: NSPersistentStore,
                                      context: NSManagedObjectContext) -> Set<UUID> {
        let request = HouseholdRecord.fetchRequest()
        request.affectedStores = [store]
        guard let records = try? context.fetch(request) else { return [] }
        return Set(records.compactMap(\.id))
    }
}
