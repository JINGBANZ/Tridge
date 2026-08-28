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
        /// The logical item a stale sheet addressed is closed — deleted,
        /// consumed to zero, or retired by a Clear All. The draft is intact and
        /// the UI offers Add as New.
        case itemUnavailable
        /// A command only a Household owner may run addressed a received one.
        case notHouseholdOwner
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
        case .itemUnavailable:
            self.init(reason: .itemUnavailable,
                      message: "That item isn't in the fridge any more. Add it as new?",
                      diagnosticID: "command.item")
        case .householdNotOwned:
            self.init(reason: .notHouseholdOwner,
                      message: "Only the person who started this fridge can change that.",
                      diagnosticID: "command.owner")
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
    /// Nil in previews, which never persist a claim.
    @ObservationIgnored private let reconciler: DuplicateReconciler?
    @ObservationIgnored private let tasks: AccountTaskRegistry
    /// Nil in the projection tests, which have no notification centre to drive.
    @ObservationIgnored private let reminders: ReminderReconciler?
    @ObservationIgnored private let today: @Sendable () -> InventoryDay
    @ObservationIgnored private var isInvalidated = false
    @ObservationIgnored private var issuedRequest: UInt64 = 0
    @ObservationIgnored private var appliedRequest: UInt64 = 0
    /// Purchases take their turn one at a time — see `awaitTurn()`.
    @ObservationIgnored private var isCommandRunning = false
    @ObservationIgnored private var waitingCommands: [CheckedContinuation<Void, Never>] = []
    /// Closed while a Household-level transition runs, so a command cannot slip
    /// in between the quiescence barrier and the copy or purge it protects.
    @ObservationIgnored private var isAdmittingCommands = true
    /// Called when CloudKit refuses a write to this Household — the signal that
    /// access was revoked, which the coordinator turns into local cleanup and a
    /// fallback.
    @ObservationIgnored var onAccessLost: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    /// Permission is asked once, on the first successful add — never from a
    /// remote import the user did not initiate.
    @ObservationIgnored private var hasAskedForNotificationPermission = false

    init(householdID: UUID, accountContext: AccountSessionContext,
         repository: any InventoryRepository, reconciler: DuplicateReconciler? = nil,
         tasks: AccountTaskRegistry, reminders: ReminderReconciler? = nil,
         today: @escaping @Sendable () -> InventoryDay = { InventoryDay.today() }) {
        self.householdID = householdID
        self.accountContext = accountContext
        self.repository = repository
        self.reconciler = reconciler
        self.tasks = tasks
        self.reminders = reminders
        self.today = today
    }

    /// The first projection after the stores open.
    ///
    /// It reconciles as well as reads: a same-name root that arrived from
    /// another device while this one was away projects as one row immediately,
    /// but has no durable claim yet until this pass writes it.
    func load() async {
        // Captured before the first suspension, like every other await in this
        // file: a Household switch during the read must not redirect the
        // reconciliation onto the fridge this pass never looked at.
        let householdID = self.householdID
        await refresh()
        await persistMergeClaims(for: householdID)
    }

    /// Switches the fridge this session projects. Snapshots are cleared first,
    /// so the previous Household's rows are never on screen under the new name.
    func select(householdID: UUID) async {
        guard householdID != self.householdID else { return }
        let previous = self.householdID
        self.householdID = householdID
        items = []
        purchaseHistory = []
        lastFailure = nil
        // The old Household's reminders and delivered alerts go before the new
        // Household's are built, using the exact prefix it was scheduled under.
        await retireReminders(for: previous)
        await load()
    }

    /// Rereads the Active Household's projection.
    func refresh() async {
        let repository = self.repository
        let householdID = self.householdID
        let day = today()
        // Taken before the read starts, so a read that resumes after a newer
        // projection has already been applied loses to it.
        let request = nextRequest()
        guard let projection = await run({
            try await repository.projection(of: householdID, today: day)
        }, for: householdID) else { return }
        apply(projection, request: request)
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
        let saved = await commit { try await repository.addManualItem(command, today: day) }
        if saved { await askForNotificationPermissionOnce() }
        return saved
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
        let saved = await commit { try await repository.addReviewedRows(command, today: day) }
        if saved { await askForNotificationPermissionOnce() }
        return saved
    }

    /// Whether this session still projects the Household a draft was filled in
    /// against, recording a failure if it does not.
    ///
    /// A form is filled in for one fridge — its quick-fill chips and its
    /// remembered art come from that fridge's history — but the session is
    /// shared and can be re-pointed while the sheet is open, by a revoked share
    /// or a fridge switch. Confirming would then put the groceries somewhere
    /// the user was never looking at. Called by the confirming sheet
    /// immediately before it commits, which is close enough: `commit` captures
    /// the Household before its first suspension, so nothing can move in
    /// between.
    func stillProjects(_ expected: UUID) -> Bool {
        guard expected != householdID else { return true }
        lastFailure = InventoryCommandFailure(InventoryRepositoryError.householdUnavailable)
        return false
    }

    // MARK: - Inventory commands

    /// Commits an Item Detail draft. Only the fields that actually moved are
    /// passed, so an untouched form writes nothing.
    ///
    /// There is no name parameter: a saved Item Name is immutable, which is
    /// what keeps every exact-name merge permanent (ADR 0005).
    ///
    /// `baselineQuantity` is the quantity the sheet was showing, and it is what
    /// the committed adjustment is measured against — so a member's operation
    /// that arrived while the sheet was open composes rather than being
    /// overwritten.
    @discardableResult
    func updateItem(_ itemID: UUID, targetQuantity: Int64? = nil,
                    baselineQuantity: Int64? = nil, artKey: String? = nil,
                    storage: StorageLocation? = nil,
                    expiryDay: InventoryDay? = nil) async -> Bool {
        let command = UpdateItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: itemID, stockChangeID: UUID(),
                                        targetQuantity: targetQuantity,
                                        baselineQuantity: baselineQuantity, artKey: artKey,
                                        storage: storage, expiryDay: expiryDay)
        let repository = self.repository
        let day = today()
        return await commit { try await repository.updateItem(command, today: day) }
    }

    /// Eats one unit of a logical item.
    @discardableResult
    func eatOne(_ itemID: UUID) async -> Bool {
        await consume(itemID, reason: .eaten)
    }

    /// Tosses one unit of a logical item.
    @discardableResult
    func tossOne(_ itemID: UUID) async -> Bool {
        await consume(itemID, reason: .tossed)
    }

    /// Closes one logical item permanently. Its history stays exportable.
    @discardableResult
    func deleteItem(_ itemID: UUID) async -> Bool {
        let command = DeleteItemCommand(householdID: householdID, commandID: UUID(),
                                        itemID: itemID, stockChangeID: UUID())
        let repository = self.repository
        let day = today()
        return await commit { try await repository.deleteItem(command, today: day) }
    }

    /// Clear All: advances the Household's causal frontier by one leaf. It
    /// writes no item-level event, so an item an offline peer adds from the
    /// superseded frontier cannot reappear (ADR 0009).
    @discardableResult
    func clearAll() async -> Bool {
        let command = ClearHouseholdCommand(householdID: householdID, commandID: UUID(),
                                            clearRecordID: UUID(), epochID: UUID())
        let repository = self.repository
        let day = today()
        return await commit { try await repository.clearActiveHousehold(command, today: day) }
    }

    private func consume(_ itemID: UUID, reason: StockReason) async -> Bool {
        guard let command = ConsumeItemCommand(householdID: householdID, commandID: UUID(),
                                               itemID: itemID, stockChangeID: UUID(),
                                               reason: reason) else { return false }
        let repository = self.repository
        let day = today()
        return await commit { try await repository.consumeItem(command, today: day) }
    }

    /// Closes command admission for this Household and waits for every writer
    /// that was already admitted to return.
    ///
    /// This is a local quiescence barrier, not a cross-device lock: it makes
    /// "the inventory this installation can see" a fixed thing for as long as a
    /// copy or a purge needs it to be.
    func closeCommandAdmission() async {
        isAdmittingCommands = false
        await awaitTurn()
        endTurn()
    }

    /// Reopens admission after a transition that did not remove the Household.
    func reopenCommandAdmission() {
        isAdmittingCommands = true
    }

    /// Renames the Household this session projects.
    ///
    /// Owner-only: the repository refuses a Household that arrived through
    /// someone else's share, because its name belongs to the owner's record.
    /// Returns the saved snapshot, or nil with `lastFailure` set.
    func renameHousehold(to name: String) async -> HouseholdSnapshot? {
        let command = RenameHouseholdCommand(householdID: householdID, commandID: UUID(),
                                             name: name)
        let repository = self.repository
        guard !isInvalidated else { return nil }
        do {
            return try await tasks.run(context: accountContext) {
                try await repository.renameOwnedHousehold(command)
            }
        } catch is AccountTaskRegistry.Rejection {
            return nil
        } catch {
            guard !isInvalidated else { return nil }
            let failure = InventoryCommandFailure(error)
            AppLog.household.error("Rename failed: \(failure.diagnosticID)")
            lastFailure = failure
            return nil
        }
    }

    /// Dismisses the last failure once the user has seen it, so a later sheet
    /// does not reopen an alert about a draft that is long gone.
    func clearFailure() {
        lastFailure = nil
    }

    /// Rebuilds the Active Household's reminders — the reminder-hour change and
    /// foreground refresh both land here.
    func refreshReminders() {
        reconcileReminders()
    }

    /// Retires one Household's pending requests and delivered alerts.
    func retireReminders(for householdID: UUID) async {
        guard let reminders else { return }
        reminderTask?.cancel()
        let scope = ReminderScope.household(accountScope: accountContext.accountScope.value,
                                            householdID: householdID)
        _ = try? await tasks.run(context: accountContext) {
            await reminders.retire(scope: scope)
        }
    }

    /// Stops this session applying anything else. Called before the account's
    /// stores are drained and removed.
    func invalidate() {
        isInvalidated = true
        reminderTask?.cancel()
        reminderTask = nil
        items = []
        purchaseHistory = []
        lastFailure = nil
    }

    // MARK: - Command plumbing

    private func commit(
        _ operation: @escaping @Sendable () async throws -> HouseholdProjection
    ) async -> Bool {
        // The fridge this command was built for, read before it suspends: the
        // claims it makes durable belong to that Household even if a switch
        // has since re-pointed the session.
        let householdID = self.householdID
        await awaitTurn()
        defer { endTurn() }
        guard isAdmittingCommands else {
            // A Household-level transition owns this fridge right now. Nothing
            // was written and the caller's draft is intact.
            lastFailure = InventoryCommandFailure(
                InventoryRepositoryError.householdUnavailable)
            return false
        }
        // Cleared once this purchase is the one actually writing, so a purchase
        // waiting its turn cannot wipe the failure of the one still running.
        lastFailure = nil
        guard let projection = await run(operation, for: householdID) else { return false }
        // Taken only once the write has returned: a command's projection
        // already contains its own save, so it is newer than every read that
        // was in flight while it ran, whenever those reads resume — and, with
        // purchases taking their turn, than every purchase that saved before it.
        apply(projection, request: nextRequest())
        // The projector already applied the same exact-name union in memory, so
        // this only makes the link durable — the UI never waits for it.
        await persistMergeClaims(for: householdID)
        return true
    }

    /// A purchase is the first thing a user does that has anything to remind
    /// them about, so permission is asked here rather than at launch.
    private func askForNotificationPermissionOnce() async {
        guard let reminders, !hasAskedForNotificationPermission else { return }
        hasAskedForNotificationPermission = true
        await reminders.requestPermissionIfNeeded()
    }

    /// Brings reminders and the badge in line with the snapshots now on screen.
    ///
    /// Registered like every other account-bound operation, and superseded
    /// rather than queued: only the newest snapshots matter, and the diff makes
    /// a skipped intermediate pass invisible.
    private func reconcileReminders() {
        guard let reminders, !isInvalidated else { return }
        let items = self.items
        let accountContext = self.accountContext
        let householdID = self.householdID
        let tasks = self.tasks
        reminderTask?.cancel()
        reminderTask = Task {
            _ = try? await tasks.run(context: accountContext) {
                await reminders.reconcile(items: items,
                                          accountScope: accountContext.accountScope,
                                          householdID: householdID)
            }
        }
    }

    /// `householdID` is the fridge the operation was *issued for*, captured
    /// before it suspended. A refused write has to be attributed to that one
    /// rather than to whatever the session projects by the time it returns: a
    /// switch made while the command was in flight would otherwise report the
    /// newly selected Household as revoked, and the coordinator would purge its
    /// shared-store graph.
    private func run(
        _ operation: @escaping @Sendable () async throws -> HouseholdProjection,
        for householdID: UUID
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
            if failure.reason == .permissionDenied {
                // CloudKit is the authority: a refused write is how a member
                // learns their access is gone.
                onAccessLost?(householdID)
            }
            return nil
        }
    }

    private func persistMergeClaims(for householdID: UUID) async {
        guard let reconciler else { return }
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

    /// Holds a purchase until the one before it has applied.
    ///
    /// The repository serializes the saves themselves, but nothing ties that
    /// order to this session: each command reaches `AccountTaskRegistry` as its
    /// own unstructured task, so two overlapping purchases can save in either
    /// order and can resume here in either order afterwards. A ticket — taken
    /// before the suspension or after the write — only ranks the applications;
    /// it cannot tell which projection was taken last, so the older
    /// transaction's, which predates the newer purchase, could be the one left
    /// on screen and hide a just-confirmed item until the next refresh.
    ///
    /// With one purchase in flight at a time, the transaction order, the ticket
    /// order, and the application order are all the same order.
    private func awaitTurn() async {
        guard isCommandRunning else {
            isCommandRunning = true
            return
        }
        await withCheckedContinuation { waitingCommands.append($0) }
    }

    /// Hands the turn to the next waiting purchase, or ends it. The flag stays
    /// set while it is handed over, so a purchase issued in between cannot barge
    /// past one that is already waiting.
    private func endTurn() {
        if waitingCommands.isEmpty {
            isCommandRunning = false
        } else {
            waitingCommands.removeFirst().resume()
        }
    }

    /// The next snapshot-application ticket. `@MainActor` does not order these
    /// on its own: `refresh()` and `commit()` both suspend across their
    /// repository awaits and can resume in either order.
    private func nextRequest() -> UInt64 {
        issuedRequest += 1
        return issuedRequest
    }

    /// The main-actor apply boundary: a projection produced for the previous
    /// account, for a Household this session no longer shows, or older than one
    /// already on screen is dropped even though its read was already running.
    private func apply(_ projection: HouseholdProjection, request: UInt64) {
        guard !isInvalidated, projection.householdID == householdID,
              request > appliedRequest else { return }
        appliedRequest = request
        items = projection.items
        purchaseHistory = projection.physicalItems
        for issue in projection.issues {
            AppLog.household.error("Omitted a corrupt record: \(issue.diagnosticDescription)")
        }
        for issue in projection.stockIssues {
            AppLog.household.error("Stock integrity: \(issue.diagnosticDescription)")
        }
        // Every snapshot application is exactly "the inventory changed", which
        // is the contract's trigger for reminder and badge reconciliation.
        reconcileReminders()
    }
}

#if DEBUG
extension HouseholdSession {
    /// A session pre-seeded with snapshots, for Xcode previews.
    ///
    /// It is built in this file because `items` and `purchaseHistory` are
    /// `private(set)`: previews render the fixture directly rather than going
    /// through a repository, so no store is needed to see the grid.
    static func preview(items: [InventoryItemSnapshot] = PreviewData.previewItems(),
                        history: [PhysicalItemSnapshot] = PreviewData.previewHistory())
    -> HouseholdSession {
        let householdID = UUID()
        let session = HouseholdSession(
            householdID: householdID,
            accountContext: PreviewData.previewAccountContext,
            repository: PreviewInventoryRepository(
                fixed: HouseholdProjection(householdID: householdID, items: items,
                                                groups: [], physicalItems: history,
                                                inferredClaims: [], issues: [],
                                                stockIssues: [])),
            tasks: AccountTaskRegistry())
        session.items = items
        session.purchaseHistory = history
        return session
    }
}
#endif
