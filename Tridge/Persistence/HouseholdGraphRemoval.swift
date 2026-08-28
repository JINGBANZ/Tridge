import CoreData

extension PersistenceController {
    /// A Household's local graph could not be removed, or is still there after
    /// a removal reported success. Retryable; the id is content-free.
    struct GraphRemovalError: Error, Equatable {
        let diagnosticID: String
    }

    /// Whether this Household is still present locally, in either store.
    ///
    /// Purging a zone removes both the CloudKit records and the local Core Data
    /// graph, but "the server zone is gone" is not the same claim as "nothing
    /// of it is left on this device" — so every lifecycle path asks this before
    /// it calls itself finished.
    /// Throws rather than answering `false` when the store cannot be read: an
    /// unanswerable question is not proof of absence, and every caller treats a
    /// `false` here as licence to finish a destructive transition.
    func containsHousehold(_ householdID: UUID) async throws -> Bool {
        let context = newReaderContext()
        return try await context.perform {
            let request = HouseholdRecord.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
            request.fetchLimit = 1
            do {
                return try context.count(for: request) > 0
            } catch {
                let details = error as NSError
                throw GraphRemovalError(
                    diagnosticID: "graph.count.\(details.domain).\(details.code)")
            }
        }
    }

    /// Deletes a Household and everything cascading from it, in one confined
    /// transaction, then verifies it is really gone.
    ///
    /// Used as cleanup after a purge — including a purge that reported the
    /// server zone already missing — never as a substitute for one: deleting
    /// locally only queues a CloudKit export, which is why owner deletion has
    /// its own verified completion path.
    func removeLocalGraph(of householdID: UUID) async throws {
        let context = newWriterContext()
        try await context.perform {
            for store in [self.privateStore, self.sharedStore] {
                let request = HouseholdRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", householdID as NSUUID)
                request.affectedStores = [store]
                for record in try context.fetch(request) {
                    context.delete(record)
                }
            }
            guard context.hasChanges else { return }
            do {
                try context.save()
            } catch {
                let details = error as NSError
                throw GraphRemovalError(
                    diagnosticID: "graph.delete.\(details.domain).\(details.code)")
            }
        }

        guard try await !containsHousehold(householdID) else {
            throw GraphRemovalError(diagnosticID: "graph.verify")
        }
    }

    /// Removes whatever of a Household is still local, and verifies absence.
    /// Absent already is success, which is what makes the cleanup idempotent
    /// across a crash between the purge and the check.
    func ensureLocalGraphAbsent(of householdID: UUID) async throws {
        guard try await containsHousehold(householdID) else { return }
        try await removeLocalGraph(of: householdID)
    }
}
