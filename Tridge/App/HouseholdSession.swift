import Foundation
import Observation

/// A command failure the UI can show while the user's draft stays open.
///
/// Content-free by contract: the message names no household, item, or quantity,
/// and the diagnostic id is safe to quote in a support report.
struct InventoryCommandFailure: Equatable, Sendable, Identifiable {
    enum Reason: Equatable, Sendable {
        /// CloudKit no longer permits writing to this Household.
        case permissionDenied
        /// The Household is gone from this account: deleted, left, or revoked.
        case householdUnavailable
        /// The draft itself cannot be saved — an empty name, a quantity that is
        /// not a positive whole number.
        case invalidCommand
        /// Stored data disagrees with what the command would have written.
        case integrity
        /// The stores are there but the save did not go through.
        case unavailable
    }

    let reason: Reason
    let message: String
    let diagnosticID: String

    var id: String { diagnosticID }

    init(_ error: Error) {
        switch error {
        case let failure as InventoryRepositoryError:
            self.init(repository: failure)
        case let invalid as InventoryCommandError:
            self.init(reason: .invalidCommand, message: Self.message(for: invalid),
                      diagnosticID: "command.invalid.\(invalid)")
        default:
            self.init(reason: .unavailable, message: Self.retryMessage,
                      diagnosticID: "command.unresolved")
        }
    }

    private init(repository failure: InventoryRepositoryError) {
        switch failure {
        case .permissionDenied:
            self.init(reason: .permissionDenied,
                      message: "You no longer have permission to change this household.",
                      diagnosticID: "command.permission")
        case .householdUnavailable:
            self.init(reason: .householdUnavailable,
                      message: "That fridge isn't available on this device any more.",
                      diagnosticID: "command.household")
        case .conflictingRetry:
            self.init(reason: .integrity, message: Self.integrityMessage,
                      diagnosticID: "command.conflict")
        case .unreadableFrontier:
            self.init(reason: .integrity, message: Self.integrityMessage,
                      diagnosticID: "command.frontier")
        case .saveFailed(let diagnosticID):
            self.init(reason: .unavailable, message: Self.retryMessage,
                      diagnosticID: diagnosticID)
        }
    }

    private init(reason: Reason, message: String, diagnosticID: String) {
        self.reason = reason
        self.message = message
        self.diagnosticID = diagnosticID
    }

    private static let retryMessage = "Tridge couldn't save that. Try again."
    private static let integrityMessage =
        "Tridge couldn't save that safely, so nothing was changed."

    private static func message(for error: InventoryCommandError) -> String {
        switch error {
        case .emptyItemName: "Give the item a name."
        case .emptyHouseholdName: "Give the fridge a name."
        case .quantityNotPositive: "Quantity has to be at least 1."
        case .quantityNotANumber: "Quantity has to be a whole number."
        case .quantityOutOfRange: "That quantity is too large."
        case .noRows: "There's nothing to add."
        case .duplicatePreallocatedID, .noChanges: integrityMessage
        }
    }
}

/// The Active Household's Inventory, as immutable value snapshots.
///
/// This is the only inventory state SwiftUI sees: Home's grid, its search and
/// filters, the header's unit count, manual add's quick-fill history, and the
/// receipt review's confirmation all read from `items` and `purchaseHistory`.
/// No managed object crosses this boundary, so nothing a view holds can outlive
/// the context — or the account — that produced it.
///
/// It is bound to one account generation. When the account changes the
/// coordinator invalidates it, so a command or refresh that was already in
/// flight cannot apply the previous account's inventory to the new one.
@MainActor
@Observable
final class HouseholdSession {
    private(set) var householdID: UUID
    /// Visible logical rows, soonest expiry first.
    private(set) var items: [InventoryItemSnapshot] = []
    /// Every physical root this Household ever saved, including superseded,
    /// zero, and deleted ones — the quick-fill and remembered-art source.
    private(set) var purchaseHistory: [PhysicalItemSnapshot] = []
    /// The last command that could not be applied. The caller's draft is
    /// untouched, so the user can correct it or try again.
    private(set) var lastFailure: InventoryCommandFailure?

    @ObservationIgnored private let accountContext: AccountSessionContext
    @ObservationIgnored private let repository: any InventoryRepository
    @ObservationIgnored private let reconciler: DuplicateReconciler
    @ObservationIgnored private let tasks: AccountTaskRegistry
    @ObservationIgnored private let today: @Sendable () -> InventoryDay
    @ObservationIgnored private var isInvalidated = false

    init(householdID: UUID, accountContext: AccountSessionContext,
         repository: any InventoryRepository, reconciler: DuplicateReconciler,
         tasks: AccountTaskRegistry,
         today: @escaping @Sendable () -> InventoryDay = { InventoryDay.today() }) {
        self.householdID = householdID
        self.accountContext = accountContext
        self.repository = repository
        self.reconciler = reconciler
        self.tasks = tasks
        self.today = today
    }

    /// The first projection after the stores open.
    ///
    /// It reconciles as well as reads: a same-name root that arrived from
    /// another device while this one was away projects as one row immediately,
    /// but has no durable claim yet until this pass writes it.
    func load() async {
        await refresh()
        await persistMergeClaims()
    }

    /// Switches the fridge this session projects. Snapshots are cleared first,
    /// so the previous Household's rows are never on screen under the new name.
    func select(householdID: UUID) async {
        guard householdID != self.householdID else { return }
        self.householdID = householdID
        items = []
        purchaseHistory = []
        lastFailure = nil
        await load()
    }

    /// Rereads the Active Household's projection.
    func refresh() async {
        let repository = self.repository
        let householdID = self.householdID
        let day = today()
        guard let projection = await run({
            try await repository.projection(of: householdID, today: day)
        }) else { return }
        apply(projection)
    }

    // MARK: - Purchases

    /// Confirms one hand-typed purchase. Returns whether it was saved; on
    /// `false` nothing was written and the caller's draft is still valid.
    @discardableResult
    func addManualItem(_ draft: PurchaseDraft) async -> Bool {
        let command = AddManualItemCommand(householdID: householdID, commandID: UUID(),
                                           draft: draft)
        let repository = self.repository
        let day = today()
        return await commit { try await repository.addManualItem(command, today: day) }
    }

    /// Confirms a whole reviewed receipt in one atomic save. The rows carry the
    /// preallocated ids allocated with the draft, so a crash-resume writes each
    /// purchase exactly once. Raw receipt-line text stays in the caller's
    /// in-memory draft and is never part of a `PurchaseDraft`.
    @discardableResult
    func addReviewedRows(_ drafts: [PurchaseDraft]) async -> Bool {
        let command = AddReviewedRowsCommand(householdID: householdID, commandID: UUID(),
                                             rows: drafts)
        let repository = self.repository
        let day = today()
        return await commit { try await repository.addReviewedRows(command, today: day) }
    }

    func clearFailure() {
        lastFailure = nil
    }

    /// Stops this session applying anything else. Called before the account's
    /// stores are drained and removed.
    func invalidate() {
        isInvalidated = true
        items = []
        purchaseHistory = []
        lastFailure = nil
    }

    // MARK: - Command plumbing

    private func commit(
        _ operation: @escaping @Sendable () async throws -> HouseholdProjection
    ) async -> Bool {
        lastFailure = nil
        guard let projection = await run(operation) else { return false }
        apply(projection)
        // The projector already applied the same exact-name union in memory, so
        // this only makes the link durable — the UI never waits for it.
        await persistMergeClaims()
        return true
    }

    private func run(
        _ operation: @escaping @Sendable () async throws -> HouseholdProjection
    ) async -> HouseholdProjection? {
        guard !isInvalidated else { return nil }
        do {
            return try await tasks.run(context: accountContext, operation: operation)
        } catch is AccountTaskRegistry.Rejection {
            // The account changed while this was starting; the transition that
            // invalidated the generation owns the state now.
            return nil
        } catch {
            guard !isInvalidated else { return nil }
            let failure = InventoryCommandFailure(error)
            AppLog.household.error("Inventory command failed: \(failure.diagnosticID)")
            lastFailure = failure
            return nil
        }
    }

    private func persistMergeClaims() async {
        let reconciler = self.reconciler
        let householdID = self.householdID
        let day = today()
        do {
            _ = try await tasks.run(context: accountContext) {
                try await reconciler.reconcile(householdID: householdID, today: day)
            }
        } catch is AccountTaskRegistry.Rejection {
        } catch {
            // Nothing the user can see changed: the rows already project as one
            // logical item, and the next reconciliation pass tries again.
            AppLog.household.error("Could not persist merge claims")
        }
    }

    /// The main-actor apply boundary: a projection produced for the previous
    /// account, or for a Household this session no longer shows, is dropped
    /// even though its read was already running.
    private func apply(_ projection: HouseholdProjection) {
        guard !isInvalidated, projection.householdID == householdID else { return }
        items = projection.items
        purchaseHistory = projection.physicalItems
        for issue in projection.issues {
            AppLog.household.error("Omitted a corrupt record: \(issue.diagnosticDescription)")
        }
        for issue in projection.stockIssues {
            AppLog.household.error("Stock integrity: \(issue.diagnosticDescription)")
        }
    }
}
