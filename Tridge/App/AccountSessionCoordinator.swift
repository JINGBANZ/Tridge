import CloudKit
import CoreData
import Foundation
import Observation

/// One account's activated session: the context every store-bound call carries,
/// and the stack it may touch.
struct AccountSession {
    let context: AccountSessionContext
    let persistence: PersistenceController
}

/// Owns the account lifecycle: validate the iCloud identity, prepare sync
/// observation *before* the stores exist, load them under one generation, and
/// tear the whole generation down when the account changes.
///
/// The ordering is the point. Observation starts first so a setup or import
/// that runs during `loadPersistentStores` is not lost; the generation is
/// created first so late work can be recognized as stale; and an account change
/// closes admission and drains every registered operation *before* a store is
/// removed, because Core Data faults if a `perform` body outlives its store.
@MainActor
@Observable
final class AccountSessionCoordinator {
    private(set) var launchState: LaunchState = .preparing
    private(set) var session: AccountSession?
    /// Whether `My Fridge` may be created for an empty cache — see
    /// `HouseholdSelection.choose(saved:available:hasCompletedInitialImport:)`.
    private(set) var hasCompletedInitialPrivateImport = false
    /// Every Household this account can reach, across both stores.
    private(set) var households: [HouseholdSnapshot] = []
    /// The selected Household, resolved by the deterministic fallback and
    /// revalidated on every launch.
    private(set) var activeHouseholdID: UUID?
    /// Whether the upgraded installation still owes the user the one-time
    /// explanation that its fridge moved. Survives termination until Continue.
    private(set) var showsMigrationNotice = false
    /// The archive could not be migrated. Inventory is usable; the archive is
    /// intact; Retry is the only thing this asks for.
    private(set) var legacyMigrationFailure: LegacyMigrationFailure?
    /// The Active Household's Inventory, as value snapshots. Exists only while
    /// a Household is selected for the current generation.
    private(set) var inventory: HouseholdSession?
    /// Overall sync health for this session's two stores. Diagnostic only: it
    /// never claims another device has received a change.
    private(set) var syncStatus: SyncStatus = .syncing
    /// True while a Household-level transition — rename, share, leave, stop,
    /// delete — is running. Every such control reads it, so none can be started
    /// twice or started on top of another.
    private(set) var isHouseholdActionInFlight = false
    /// The last Household-level action that could not be completed. Nothing was
    /// changed, and the message names no fridge, member, or share.
    private(set) var householdFailure: HouseholdActionFailure?
    /// The share an owner just prepared, ready for `ShareLink`. Cleared once the
    /// share sheet closes, so the next invitation refreshes the title again.
    private(set) var preparedShare: HouseholdShareItem?
    /// Households whose share title could not be written. Their invitation
    /// would show a stale fridge name, so Send Invite retries the write first.
    private(set) var householdsWithStaleShareTitle: Set<UUID> = []
    /// Households hidden from normal interaction while they are being removed
    /// or recovered. They are out of the picker and out of selection, and their
    /// reminders are already retired.
    private(set) var suppressedHouseholdIDs: Set<UUID> = []
    /// A multi-step lifecycle change this installation is part-way through.
    /// It survives termination and is resumed before normal selection.
    private(set) var pendingLifecycleTransition: HouseholdLifecycleTransition?
    /// A CloudKit failure no retry can fix, waiting on the user's decision.
    /// While it stands, the Households it names are hidden.
    private(set) var pendingRecovery: HouseholdRecoveryRequest?
    /// A written export waiting for the system share sheet. Temporary, and
    /// cleared once the sheet closes.
    private(set) var exportedDocumentURL: URL?
    /// Whether the archived pre-sharing store is still on this device. The
    /// files are the record, so this needs no marker of its own.
    private(set) var hasLegacyArchive: Bool

    let tasks: AccountTaskRegistry
    let syncMonitor: any SyncStatusProviding
    /// Where a tapped invitation lands, whether the scene was already connected
    /// or was connected by the tap itself.
    let invitations: ShareInvitationRouter

    /// The Active Household's snapshot, when one is selected and still valid.
    var activeHousehold: HouseholdSnapshot? {
        guard let activeHouseholdID else { return nil }
        return households.first { $0.id == activeHouseholdID }
    }

    private let identity: any AccountIdentityProviding
    let reminders: ReminderReconciler
    /// Where the per-store history cursors live. Injected so a test suite keeps
    /// its own, rather than writing into the host's standard defaults.
    private let defaults: UserDefaults
    private let barrier: BootstrapBarrierStore
    private let activeHouseholds: ActiveHouseholdStore
    private let upgrade: LegacyInventoryUpgrade
    private let eraser: LegacyArchiveEraser
    private let makePersistence: @Sendable (AccountScopeHash) async throws -> PersistenceController
    private let makeSharing: @MainActor (PersistenceController) -> any HouseholdSharing

    /// The coordinator's own mirror of the registry's open generation. Work
    /// applying its result on the main actor checks this, so a value produced
    /// for the previous account cannot land on the current one.
    /// Lifecycle bookkeeping rather than UI state, so none of it is observed.
    @ObservationIgnored private var currentGeneration: AccountGeneration?
    /// What an invalidated generation still owns: sync observation to end and
    /// stores to release, once the registry has drained.
    @ObservationIgnored private var retiredGeneration: AccountGeneration?
    @ObservationIgnored private var retiredSession: AccountSession?
    /// The `CKAccountChanged` observer, held in a token that unregisters
    /// itself when the coordinator is released.
    @ObservationIgnored private let accountObserver = NotificationObserverToken()
    /// The remote-change observer for the current generation's coordinator.
    @ObservationIgnored private let remoteChangeObserver = NotificationObserverToken()
    /// The current generation's history consumer. Released with the generation,
    /// so a late notification cannot reach a removed store.
    @ObservationIgnored private var history: PersistentHistoryProcessor?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var barrierWatch: Task<Void, Never>?
    @ObservationIgnored private var upgradeTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?
    /// The last account scope whose reminders this installation scheduled.
    /// Kept so an account change can retire that exact prefix — including the
    /// alerts already delivered — without touching another scope.
    @ObservationIgnored private var lastValidatedScope: AccountScopeHash?
    @ObservationIgnored private var syncStatusTask: Task<Void, Never>?
    /// This generation's share operations. Released with the generation, so a
    /// late invitation cannot reach a removed store.
    @ObservationIgnored private var sharing: (any HouseholdSharing)?
    @ObservationIgnored private var shareTitles: ShareTitleRetryStore?
    @ObservationIgnored private var transitions: LifecycleTransitionStore?
    /// The last share status the container reported. Overlaid onto every
    /// snapshot, because share metadata never appears in persistent history.
    @ObservationIgnored private var sharedHouseholdIDs: Set<UUID> = []
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init(identity: any AccountIdentityProviding = CloudKitAccountIdentity(),
         syncMonitor: any SyncStatusProviding,
         tasks: AccountTaskRegistry = AccountTaskRegistry(),
         reminders: ReminderReconciler = ReminderReconciler(),
         defaults: UserDefaults = .standard,
         barrier: BootstrapBarrierStore = BootstrapBarrierStore(),
         activeHouseholds: ActiveHouseholdStore = ActiveHouseholdStore(),
         upgrade: LegacyInventoryUpgrade = LegacyInventoryUpgrade(),
         eraser: LegacyArchiveEraser = LegacyArchiveEraser(),
         invitations: ShareInvitationRouter = .shared,
         makePersistence: @escaping @Sendable (AccountScopeHash) async throws
             -> PersistenceController = AccountSessionCoordinator.loadCloudKitStack,
         makeSharing: @escaping @MainActor (PersistenceController) -> any HouseholdSharing
             = { CloudKitHouseholdSharing(persistence: $0) }) {
        self.identity = identity
        self.reminders = reminders
        self.defaults = defaults
        self.syncMonitor = syncMonitor
        self.tasks = tasks
        self.barrier = barrier
        self.activeHouseholds = activeHouseholds
        self.upgrade = upgrade
        self.eraser = eraser
        self.hasLegacyArchive = eraser.hasRemnants
        self.invitations = invitations
        self.makePersistence = makePersistence
        self.makeSharing = makeSharing
        self.showsMigrationNotice = upgrade.needsNotice
    }

    static let loadCloudKitStack: @Sendable (AccountScopeHash) async throws -> PersistenceController = {
        scope in
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try await PersistenceController.load(
            configuration: .cloudKit(accountScope: scope, baseDirectory: base))
    }

    // MARK: - Launch

    /// Validates the account and brings up its stack. Safe to call again for
    /// Retry: an existing session is torn down first.
    func start() async {
        await enqueueTransition { await self.restart() }
    }

    /// Mirrors the monitor's status into observed state, so the Household
    /// screen can render it without owning an `AsyncStream` of its own.
    func observeSyncStatus() {
        guard syncStatusTask == nil else { return }
        let updates = syncMonitor.statusUpdates
        syncStatusTask = Task { [weak self] in
            for await status in updates {
                guard let self else { return }
                self.syncStatus = status
            }
        }
    }

    /// Begins observing `CKAccountChanged`. Separate from `start()` so tests
    /// can drive transitions deterministically.
    func observeAccountChanges() {
        guard !accountObserver.isRegistered else { return }
        accountObserver.register {
            NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.accountDidChange() }
            }
        }
    }

    /// The account changed: rebuild everything under a new generation.
    ///
    /// Invalidation is synchronous so a load that is already in flight cannot
    /// activate the previous account's stores once it returns. The rest is
    /// queued behind any transition already running, so two notifications
    /// cannot tear down the same stack twice.
    func accountDidChange() {
        invalidateVisibleState()
        Task { await self.enqueueTransition { await self.restart() } }
    }

    /// Releases the session without starting another — app teardown and tests.
    func shutDown() async {
        await enqueueTransition { await self.invalidateCurrentSession() }
    }

    private func enqueueTransition(_ body: @escaping @MainActor () async -> Void) async {
        let previous = transitionTask
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        transitionTask = task
        await task.value
    }

    private func restart() async {
        await invalidateCurrentSession()
        await validateAndLoad()
    }

    /// Stops results of the current generation from reaching the UI, and hands
    /// what it still owns to the transition that will drain it. Synchronous on
    /// purpose: everything after this point can suspend, and none of it may run
    /// while account A's inventory is still on screen.
    private func invalidateVisibleState() {
        if let currentGeneration { retiredGeneration = currentGeneration }
        if let session { retiredSession = session }
        currentGeneration = nil
        session = nil
        launchState = .preparing
        hasCompletedInitialPrivateImport = false
        households = []
        activeHouseholdID = nil
        legacyMigrationFailure = nil
        // Inventory stops applying before anything else suspends, so account
        // A's rows cannot still be on screen while account B loads. The work it
        // registered is drained with the rest of the generation.
        inventory?.invalidate()
        inventory = nil
        inventoryTask?.cancel()
        inventoryTask = nil
        // Nothing new may be admitted for this generation, so the observer goes
        // before the drain rather than after it.
        remoteChangeObserver.remove()
        history = nil
        syncStatus = .syncing
        isHouseholdActionInFlight = false
        householdFailure = nil
        preparedShare = nil
        householdsWithStaleShareTitle = []
        suppressedHouseholdIDs = []
        sharedHouseholdIDs = []
        pendingLifecycleTransition = nil
        pendingRecovery = nil
        // The router keeps its metadata for this process, but it may not accept
        // into a store that is about to be removed.
        invitations.bind(accept: nil)
        sharing = nil
        shareTitles = nil
        transitions = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        barrierWatch?.cancel()
        barrierWatch = nil
        // The migration itself is registered work, so the drain waits for it;
        // this only stops its result from applying to the next account.
        upgradeTask?.cancel()
        upgradeTask = nil
    }

    /// The account transition, in the order the stores require: invalidate and
    /// close admission, close inventory UI, drain every registered operation,
    /// end sync observation, and only then release the stores.
    private func invalidateCurrentSession() async {
        invalidateVisibleState()
        await tasks.close()
        await tasks.cancelAndDrain()

        if let retiredGeneration {
            syncMonitor.endSession(generation: retiredGeneration)
        }
        retiredSession?.persistence.tearDown()
        retiredGeneration = nil
        retiredSession = nil
    }

    private func validateAndLoad() async {
        // Before the account is consulted and before any store is opened: an
        // installation that is signed out or restricted must still stop the
        // previous build's reminders for an inventory that is moving.
        upgrade.cleanUpLegacyEffectsIfNeeded()

        let accountScope: AccountScopeHash
        do {
            accountScope = try await identity.validateCurrentAccountScope()
        } catch let error as AccountIdentityError {
            syncMonitor.updateAccountState(.unavailable)
            let state = LaunchState(accountError: error)
            // Only a settled signed-out or restricted account retires the
            // previous scope's reminders. A transient lookup failure is not
            // evidence that the account went away, and wiping the schedule on
            // it would stop notifying for a fridge that is still there.
            if case .iCloudAccountRequired(let availability) = state, !availability.isTransient {
                await retireRemindersOfPreviousAccount(replacedBy: nil)
            }
            launchState = state
            return
        } catch {
            // An unmodelled failure is undetermined, not signed out: a cold
            // launch retries rather than guessing which account it is.
            syncMonitor.updateAccountState(.unavailable)
            launchState = .iCloudAccountRequired(.couldNotDetermine)
            return
        }

        syncMonitor.updateAccountState(.validated)
        // Before this account's own reminders are built, and using the exact
        // prefix the previous one scheduled under.
        await retireRemindersOfPreviousAccount(replacedBy: accountScope)
        lastValidatedScope = accountScope
        let generationContext = AccountGenerationContext(accountScope: accountScope)
        currentGeneration = generationContext.generation
        await tasks.open(generationContext.generation)
        // Before any store can start setup or import work.
        syncMonitor.prepareSession(generation: generationContext.generation)

        do {
            // Loading both stores and activating the session is one registered
            // operation, so a drain cannot return while a store this generation
            // opened is still unaccounted for.
            let loader = makePersistence
            try await tasks.run(generation: generationContext.generation) { [weak self] in
                let controller = try await loader(accountScope)
                guard let self else {
                    controller.tearDown()
                    return
                }
                await self.activate(controller, for: generationContext)
            }
        } catch is AccountTaskRegistry.Rejection {
            // The account changed while this generation was starting; the
            // transition that invalidated it owns the state now.
        } catch let error as PersistenceController.LoadError {
            guard currentGeneration == generationContext.generation else { return }
            launchState = LaunchState(loadError: error)
        } catch {
            guard currentGeneration == generationContext.generation else { return }
            launchState = .persistenceUnavailable(diagnosticID: "store.unresolved")
        }
    }

    private func activate(_ controller: PersistenceController,
                          for generationContext: AccountGenerationContext) {
        guard currentGeneration == generationContext.generation else {
            // The account changed between the two load callbacks and the
            // return: release the stores this generation opened rather than
            // leaving their files held against the next account.
            controller.tearDown()
            return
        }

        let context = AccountSessionContext(
            generationContext: generationContext,
            privateStoreIdentifier: controller.privateStore.identifier,
            sharedStoreIdentifier: controller.sharedStore.identifier)
        syncMonitor.activateSession(generation: context.generation,
                                    storeIdentifiers: context.storeIdentifiers)
        session = AccountSession(context: context, persistence: controller)
        startSharing(for: context, controller: controller)
        applyBootstrapGate(for: context, controller: controller)
        startHistoryProcessing(for: context, controller: controller)
    }

    // MARK: - Sharing

    /// Brings up this generation's share operations and lets the router accept
    /// into the shared store that just opened.
    private func startSharing(for context: AccountSessionContext,
                              controller: PersistenceController) {
        let sharing = makeSharing(controller)
        self.sharing = sharing
        shareTitles = ShareTitleRetryStore(accountScope: context.accountScope,
                                           defaults: defaults)
        transitions = LifecycleTransitionStore(accountScope: context.accountScope,
                                               defaults: defaults)
        invitations.bind { [weak self] metadata in
            try await self?.acceptInvitation(metadata, for: context, using: sharing)
        }
        syncMonitor.onRecoveryNeeded = { [weak self] need, storeIdentifier in
            self?.handleRecoveryNeeded(need, storeIdentifier: storeIdentifier, for: context)
        }
    }

    // MARK: - Zone loss and encryption-key resets

    /// The container reported that a zone is gone or its key was rotated.
    ///
    /// The affected Households leave normal interaction immediately and their
    /// reminders are retired, because whatever happens next they cannot be
    /// synced as they are. An owner is then asked before anything local is
    /// purged; a member is not, because a member cannot recreate somebody
    /// else's zone and has nothing left to decide.
    private func handleRecoveryNeeded(_ need: SyncRecoveryNeed, storeIdentifier: String,
                                      for context: AccountSessionContext) {
        guard currentGeneration == context.generation, pendingRecovery == nil else { return }
        let role: HouseholdRecoveryRequest.Role =
            storeIdentifier == context.privateStoreIdentifier ? .owner : .member
        let affected = households
            .filter { $0.ownership == (role == .owner ? .owned : .received) }
            .map(\.id)
        guard !affected.isEmpty else { return }

        let request = HouseholdRecoveryRequest(
            cause: need == .zoneDeleted ? .zoneDeleted : .encryptionKeyReset,
            role: role, householdIDs: affected)
        let side = role == .owner ? "private" : "shared"
        AppLog.household.error("Recovery needed: \(need.rawValue) in the \(side) store")

        suppressedHouseholdIDs.formUnion(affected)
        households.removeAll { affected.contains($0.id) }
        pendingRecovery = request

        Task { [weak self] in
            guard let self else { return }
            await self.retireReminders(for: affected, in: context)
            guard !request.needsConfirmation else { return }
            // A member has nothing to confirm: the access is already gone.
            await self.confirmRecovery()
        }
    }

    /// Carries out what the pending recovery says, once the user has agreed to
    /// it — or immediately, for a member who was never asked.
    @discardableResult
    func confirmRecovery() async -> Bool {
        guard let request = pendingRecovery, let session else { return false }
        return await runHouseholdAction {
            await self.performRecovery(request, for: session)
        }
    }

    /// Dismisses the explanation. The affected Households stay hidden, because
    /// nothing about the failure has changed — an owner who taps Not Now can
    /// export first and confirm later.
    func dismissRecovery() {
        pendingRecovery = nil
    }

    private func performRecovery(_ request: HouseholdRecoveryRequest,
                                 for session: AccountSession) async -> Bool {
        householdFailure = nil
        switch request.role {
        case .member:
            // The owner's zone is theirs to rebuild. All this device can do is
            // stop offering a fridge it cannot read, and say why.
            for householdID in request.householdIDs {
                _ = await removeReceivedHousehold(householdID, stage: "recovery")
            }
            // The request stands until the user dismisses it: the cleanup needed
            // no permission, but the explanation is still owed.
            return true

        case .owner:
            // Keep the validated local cache and drop the zone it can no longer
            // be written to: the same copy-then-purge the owner's Stop Sharing
            // performs, recorded under its own name.
            guard let transitions,
                  let householdID = request.householdIDs.first,
                  let name = households.first(where: { $0.id == householdID })?.name
                      ?? recoveredHouseholdName(householdID, in: session)
            else {
                pendingRecovery = nil
                return false
            }
            let transition = HouseholdLifecycleTransition(
                kind: .recoverOwnedZone, phase: .copying, sourceHouseholdID: householdID,
                destinationHouseholdID: UUID())
            transitions.save(transition)
            applySuppression(of: transition)
            let recovered = await runStopSharing(transition, named: name, for: session)
            if recovered { pendingRecovery = nil }
            return recovered
        }
    }

    /// The name of a Household that has already been hidden, read back from the
    /// store so the copy does not lose it.
    private func recoveredHouseholdName(_ householdID: UUID,
                                        in session: AccountSession) -> String? {
        session.persistence.householdSnapshots().valid
            .first { $0.id == householdID }?.name
    }

    private func retireReminders(for householdIDs: [UUID],
                                 in context: AccountSessionContext) async {
        for householdID in householdIDs {
            await reminders.retire(scope: .household(accountScope: context.accountScope.value,
                                                     householdID: householdID))
        }
    }

    /// Accepts one invitation, registered like every other store-bound
    /// operation and refused outright once the generation has moved on.
    private func acceptInvitation(_ metadata: any ShareInvitationMetadata,
                                  for context: AccountSessionContext,
                                  using sharing: any HouseholdSharing) async throws {
        guard currentGeneration == context.generation else {
            throw HouseholdActionFailure(reason: .unavailable,
                                         message: "Tridge is still getting ready. Try again.",
                                         diagnosticID: "invitation.session")
        }
        try await tasks.run(context: context) {
            try await sharing.accept(metadata)
        }
        // Normal import brings the received Household into the list. It does
        // not become active — the member selects it explicitly (ADR 0013).
        processHistory(for: context, storeURL: nil)
        refreshShareState(for: context)
    }

    /// Re-reads which Households are shared. Deliberately scheduled rather than
    /// observed: share metadata does not produce persistent-history
    /// transactions, so nothing would ever tell us it changed.
    private func refreshShareState(for context: AccountSessionContext) {
        guard let sharing else { return }
        let ids = households.map(\.id)
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            let shared = await sharing.sharedHouseholdIDs(among: ids)
            self?.applyShareState(shared, for: context)
        }
    }

    /// The main-actor apply boundary: share status read for the previous
    /// account never reaches this one's list.
    private func applyShareState(_ shared: Set<UUID>, for context: AccountSessionContext) {
        guard currentGeneration == context.generation, sharedHouseholdIDs != shared else { return }
        sharedHouseholdIDs = shared
        households = households.map { $0.withShareState(isShared: shared.contains($0.id)) }
    }

    /// Owner-only: create or refresh the Household's share and make sure its
    /// saved title matches the current fridge name, then hand the result to
    /// `ShareLink`.
    ///
    /// The title write has to succeed first, so a reused invitation never
    /// knowingly displays a stale name; on failure nothing is presented and the
    /// retry marker survives termination.
    @discardableResult
    func prepareShare(for householdID: UUID) async -> Bool {
        await runHouseholdAction { await self.performPrepareShare(householdID) }
    }

    /// Called when the share sheet closes, so the next Send Invite refreshes the
    /// share and its title again rather than reusing this one.
    func clearPreparedShare() {
        preparedShare = nil
    }

    func clearHouseholdFailure() {
        householdFailure = nil
    }

    private func performPrepareShare(_ householdID: UUID) async -> Bool {
        guard let session, let sharing,
              let household = households.first(where: { $0.id == householdID })
        else {
            householdFailure = HouseholdActionFailure(
                reason: .householdUnavailable,
                message: "That fridge isn't available on this device any more.",
                diagnosticID: "share.household")
            return false
        }
        guard household.ownership == .owned else {
            householdFailure = HouseholdActionFailure(
                reason: .notOwner,
                message: "Only the person who started this fridge can invite people.",
                diagnosticID: "share.owner")
            return false
        }

        householdFailure = nil
        preparedShare = nil
        let context = session.context
        let name = household.name
        do {
            try await tasks.run(context: context) { [weak self] in
                let item = try await sharing.prepareShare(for: householdID, title: name)
                await self?.apply(preparedShare: item, householdID: householdID, for: context)
            }
            return preparedShare != nil
        } catch is AccountTaskRegistry.Rejection {
            return false
        } catch {
            // Inventory and the active selection are untouched: a platform
            // limit or a failed title write changes nothing local.
            householdFailure = HouseholdActionFailure(error, stage: "share")
            recordStaleShareTitle(householdID)
            return false
        }
    }

    /// The main-actor apply boundary: a share prepared for the previous account
    /// is dropped rather than offered under this one.
    private func apply(preparedShare item: HouseholdShareItem, householdID: UUID,
                       for context: AccountSessionContext) {
        guard currentGeneration == context.generation else { return }
        preparedShare = item
        shareTitles?.clear(householdID)
        householdsWithStaleShareTitle.remove(householdID)
    }

    private func recordStaleShareTitle(_ householdID: UUID) {
        shareTitles?.recordFailure(householdID)
        householdsWithStaleShareTitle.insert(householdID)
    }

    /// Renames an owned Household, then brings its share title with it.
    @discardableResult
    func renameHousehold(_ householdID: UUID, to name: String) async -> Bool {
        await runHouseholdAction { await self.performRename(householdID, to: name) }
    }

    private func performRename(_ householdID: UUID, to name: String) async -> Bool {
        guard let inventory, inventory.householdID == householdID else {
            householdFailure = HouseholdActionFailure(
                reason: .householdUnavailable,
                message: "That fridge isn't available on this device any more.",
                diagnosticID: "rename.household")
            return false
        }
        householdFailure = nil
        guard let snapshot = await inventory.renameHousehold(to: name) else {
            householdFailure = HouseholdActionFailure(
                reason: .unresolved, message: inventory.lastFailure?.message
                    ?? "Tridge couldn't rename that fridge. Try again.",
                diagnosticID: inventory.lastFailure?.diagnosticID ?? "rename.unresolved")
            return false
        }

        let wasShared = households.first { $0.id == householdID }?.isShared ?? false
        households = households.map {
            $0.id == snapshot.id ? snapshot.withShareState(isShared: wasShared) : $0
        }
        guard wasShared, let session, let sharing else { return true }
        // The Household is saved; the share's own title is a second write that
        // can fail on its own. A failure is marked rather than swallowed, and
        // Send Invite reconciles the title before it will present anything.
        do {
            try await tasks.run(context: session.context) {
                _ = try await sharing.prepareShare(for: householdID, title: snapshot.name)
            }
            shareTitles?.clear(householdID)
            householdsWithStaleShareTitle.remove(householdID)
        } catch is AccountTaskRegistry.Rejection {
        } catch {
            recordStaleShareTitle(householdID)
        }
        return true
    }

    // MARK: - Household selection

    /// Switches the Active Household.
    ///
    /// Selection is local: only the account-scoped UUID is persisted, and it is
    /// deliberately not synchronized to another device. An unknown id — one
    /// that was left, revoked, or deleted between the row being drawn and
    /// tapped — falls through to the deterministic fallback instead.
    func selectHousehold(_ id: UUID) {
        guard let session, id != activeHouseholdID else { return }
        guard households.contains(where: { $0.id == id }) else {
            selectActiveHousehold(for: session.context, controller: session.persistence)
            return
        }
        activate(householdID: id, for: session.context, controller: session.persistence)
    }

    /// Runs one Household-level transition at a time.
    ///
    /// Loading and destructive actions disable the Inventory controls while
    /// they run, and a second tap on one already running is dropped rather than
    /// queued — a duplicate purge or delete is exactly what must not happen.
    @discardableResult
    func runHouseholdAction(_ body: @MainActor () async -> Bool) async -> Bool {
        guard !isHouseholdActionInFlight else { return false }
        isHouseholdActionInFlight = true
        defer { isHouseholdActionInFlight = false }
        return await body()
    }

    // MARK: - Data rights

    /// Writes one Household's complete inventory history to a temporary file,
    /// ready for the system share sheet.
    ///
    /// Every accessible Household offers this, whatever the user's role: an
    /// export is about the data, not about who owns the share.
    @discardableResult
    func exportHousehold(_ householdID: UUID) async -> Bool {
        await runHouseholdAction { await self.performExport(householdID) }
    }

    /// Called when the share sheet closes; the temporary file is not kept
    /// around waiting to be shared a second time.
    func clearExportedDocument() {
        if let url = exportedDocumentURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        exportedDocumentURL = nil
    }

    private func performExport(_ householdID: UUID) async -> Bool {
        guard let session, households.contains(where: { $0.id == householdID }) else {
            householdFailure = HouseholdActionFailure(
                reason: .householdUnavailable,
                message: "That fridge isn't available on this device any more.",
                diagnosticID: "export.household")
            return false
        }
        householdFailure = nil
        clearExportedDocument()

        let context = session.context
        let exporter = InventoryExporter(persistence: session.persistence)
        let today = InventoryDay.today()
        do {
            let url = try await tasks.run(context: context) {
                try await exporter.exportDocument(for: householdID, today: today)
            }
            guard currentGeneration == context.generation else { return false }
            exportedDocumentURL = url
            return true
        } catch is AccountTaskRegistry.Rejection {
            return false
        } catch {
            householdFailure = HouseholdActionFailure(error, stage: "export")
            return false
        }
    }

    /// Destroys the archived pre-sharing store on this device.
    ///
    /// Deliberately separate from every Household action: the archive is
    /// installation-wide, has no safe account or Household mapping, and
    /// deleting it claims nothing about CloudKit data.
    @discardableResult
    func eraseLegacyArchive() async -> Bool {
        await runHouseholdAction {
            self.householdFailure = nil
            let eraser = self.eraser
            do {
                try await Task.detached(priority: .userInitiated) { try eraser.erase() }.value
            } catch {
                self.householdFailure = HouseholdActionFailure(error, stage: "legacyErase")
                self.hasLegacyArchive = eraser.hasRemnants
                return false
            }
            self.hasLegacyArchive = false
            return true
        }
    }

    // MARK: - Stop sharing, keep the fridge

    /// Whether the destructive share actions may run at all.
    ///
    /// They are offered only while the account and network are usable and
    /// neither store has an in-progress or failed sync event: a purge cannot be
    /// undone, and "everything I can see is really here" has to be true before
    /// the copy is taken.
    var canRunDestructiveShareAction: Bool {
        syncStatus == .upToDate && pendingLifecycleTransition == nil
    }

    /// The owner's explicit Stop Sharing. It is the only such entry point in the
    /// app — there is no hidden management path.
    ///
    /// It promises the owner's current local projection, never a peer's
    /// unexported work: CloudKit offers no acknowledgement that every member's
    /// device has uploaded, so the confirmation says so plainly.
    @discardableResult
    func stopSharing(_ householdID: UUID) async -> Bool {
        await runHouseholdAction { await self.performStopSharing(householdID) }
    }

    private func performStopSharing(_ householdID: UUID) async -> Bool {
        guard let session, let transitions,
              let household = households.first(where: { $0.id == householdID })
        else {
            householdFailure = HouseholdActionFailure(
                reason: .householdUnavailable,
                message: "That fridge isn't available on this device any more.",
                diagnosticID: "stopSharing.household")
            return false
        }
        guard household.ownership == .owned, household.isShared else {
            householdFailure = HouseholdActionFailure(
                reason: .notOwner,
                message: "Only the person who started this fridge can stop sharing it.",
                diagnosticID: "stopSharing.owner")
            return false
        }
        guard canRunDestructiveShareAction else {
            householdFailure = HouseholdActionFailure(
                reason: .unavailable,
                message: "Wait until this fridge is up to date, then try again.",
                diagnosticID: "stopSharing.notSettled")
            return false
        }

        householdFailure = nil
        // Allocated before anything happens, so every retry from here on finds
        // the same destination instead of making a second copy.
        let transition = HouseholdLifecycleTransition(
            kind: .stopSharing, phase: .copying, sourceHouseholdID: householdID,
            destinationHouseholdID: UUID())
        transitions.save(transition)
        applySuppression(of: transition)
        return await runStopSharing(transition, named: household.name, for: session)
    }

    /// Runs — or resumes — a stop-sharing transition from whatever phase it is
    /// recorded at. Each phase is entered only once, because the phase written
    /// after a step is what proves that step happened.
    private func runStopSharing(_ recorded: HouseholdLifecycleTransition, named name: String,
                                for session: AccountSession) async -> Bool {
        guard let sharing, let transitions,
              let destinationID = recorded.destinationHouseholdID
        else { return false }

        var transition = recorded
        let context = session.context
        let persistence = session.persistence
        let repository = CoreDataInventoryRepository(persistence: persistence)
        let today = InventoryDay.today()
        let source = transition.sourceHouseholdID

        do {
            if transition.phase == .copying {
                // Local quiescence: close admission and let every already
                // admitted writer return, so the projection the copy takes
                // cannot move underneath it.
                if inventory?.householdID == source {
                    await inventory?.closeCommandAdmission()
                }
                try await tasks.run(context: context) {
                    _ = try await repository.copyActiveInventory(from: source,
                                                                 into: destinationID,
                                                                 named: name, today: today)
                }
                transition.phase = .copySaved
                transitions.save(transition)
                applyTransitionPhase(transition, for: context)
            }

            if transition.phase == .copySaved {
                // Refetched through the store: a save that reported success but
                // left nothing behind must never lead to a purge.
                _ = try await tasks.run(context: context) {
                    try await repository.verifyPreservedCopy(destinationID, today: today)
                }
                transition.phase = .purgePending
                transitions.save(transition)
                applyTransitionPhase(transition, for: context)
            }

            if transition.phase == .purgePending {
                try await tasks.run(context: context) {
                    // Whether the zone goes now or was already gone, the local
                    // source graph still has to be verified absent.
                    _ = try await sharing.purgeZone(of: source, in: .privateDatabase)
                    try await persistence.ensureLocalGraphAbsent(of: source)
                }
            }
        } catch is AccountTaskRegistry.Rejection {
            return false
        } catch {
            inventory?.reopenCommandAdmission()
            householdFailure = HouseholdActionFailure(error, stage: "stopSharing")
            // A copy that saved is kept and the source stays hidden, so the
            // user never sees the same fridge twice while cleanup is retryable.
            applySuppression(of: transition)
            return false
        }

        transitions.clear()
        pendingLifecycleTransition = nil
        await finishStopSharing(source: source, destination: destinationID, for: session)
        return true
    }

    private func finishStopSharing(source: UUID, destination: UUID,
                                   for session: AccountSession) async {
        let context = session.context
        guard currentGeneration == context.generation else { return }
        suppressedHouseholdIDs.remove(destination)
        await reminders.retire(scope: .household(accountScope: context.accountScope.value,
                                                 householdID: source))
        // The verified copy is what the user should be looking at next.
        activeHouseholds.save(destination, for: context.accountScope)
        activeHouseholdID = destination
        inventory?.reopenCommandAdmission()
        selectActiveHousehold(for: context, controller: session.persistence)
    }

    // MARK: - Resuming an interrupted transition

    /// Continues whatever this installation was part-way through, before the
    /// affected Households can be interacted with again.
    private func resume(_ transition: HouseholdLifecycleTransition,
                        for context: AccountSessionContext,
                        controller: PersistenceController) {
        guard lifecycleTask == nil, let session, session.context.generation == context.generation
        else { return }
        let name = households.first { $0.id == transition.sourceHouseholdID }?.name
            ?? HouseholdSelection.defaultHouseholdName
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await self.runHouseholdAction {
                switch transition.kind {
                case .stopSharing, .recoverOwnedZone:
                    return await self.runStopSharing(transition, named: name, for: session)
                case .deletePrivate, .deleteShared:
                    return await self.runHouseholdDeletion(transition, for: session)
                }
            }
            self.lifecycleTask = nil
        }
    }

    private func applySuppression(of transition: HouseholdLifecycleTransition) {
        pendingLifecycleTransition = transition
        suppressedHouseholdIDs.formUnion(transition.suppressedHouseholdIDs)
        households.removeAll { suppressedHouseholdIDs.contains($0.id) }
    }

    /// Narrows suppression as a transition advances — the verified copy stops
    /// being hidden the moment it is real.
    private func applyTransitionPhase(_ transition: HouseholdLifecycleTransition,
                                      for context: AccountSessionContext) {
        guard currentGeneration == context.generation else { return }
        pendingLifecycleTransition = transition
        // A destination that is now real stops being hidden. Nothing else this
        // session suppressed — a leave, an access loss — is affected.
        if let destination = transition.destinationHouseholdID,
           !transition.suppressedHouseholdIDs.contains(destination) {
            suppressedHouseholdIDs.remove(destination)
        }
        suppressedHouseholdIDs.formUnion(transition.suppressedHouseholdIDs)
    }

    // MARK: - Deleting an owned Household

    /// The owner's permanent delete.
    ///
    /// An unshared fridge is deleted from CloudKit and confirmed absent there
    /// before Tridge calls it done; a shared one is purged for everyone with no
    /// copy made. Which of the two is offered is decided by whether a share
    /// exists — Delete Fridge is never an implicit Stop Sharing.
    @discardableResult
    func deleteHousehold(_ householdID: UUID) async -> Bool {
        await runHouseholdAction { await self.performDelete(householdID) }
    }

    private func performDelete(_ householdID: UUID) async -> Bool {
        guard let session, let sharing, let transitions,
              let household = households.first(where: { $0.id == householdID })
        else {
            householdFailure = HouseholdActionFailure(
                reason: .householdUnavailable,
                message: "That fridge isn't available on this device any more.",
                diagnosticID: "delete.household")
            return false
        }
        guard household.ownership == .owned else {
            householdFailure = HouseholdActionFailure(
                reason: .notOwner,
                message: "Only the person who started this fridge can delete it.",
                diagnosticID: "delete.owner")
            return false
        }
        guard canRunDestructiveShareAction else {
            householdFailure = HouseholdActionFailure(
                reason: .unavailable,
                message: "Wait until this fridge is up to date, then try again.",
                diagnosticID: "delete.notSettled")
            return false
        }

        householdFailure = nil
        // Close admission and drain before anything is captured or removed, so
        // no writer is still adding to a graph that is being deleted.
        if inventory?.householdID == householdID {
            await inventory?.closeCommandAdmission()
        }

        var transition: HouseholdLifecycleTransition
        if household.isShared {
            transition = HouseholdLifecycleTransition(kind: .deleteShared, phase: .purgePending,
                                                      sourceHouseholdID: householdID)
        } else {
            // Captured before mutation: afterwards there is nothing left to ask
            // which CloudKit records this fridge was.
            let captured: [CapturedCloudKitRecord]
            do {
                captured = try await tasks.run(context: session.context) {
                    try await sharing.capturedRecords(of: householdID)
                }
            } catch is AccountTaskRegistry.Rejection {
                inventory?.reopenCommandAdmission()
                return false
            } catch {
                inventory?.reopenCommandAdmission()
                householdFailure = HouseholdActionFailure(error, stage: "delete")
                return false
            }
            transition = HouseholdLifecycleTransition(kind: .deletePrivate,
                                                      phase: .privateDeletePrepared,
                                                      sourceHouseholdID: householdID,
                                                      capturedRecords: captured)
        }
        transitions.save(transition)
        applySuppression(of: transition)
        return await runHouseholdDeletion(transition, for: session)
    }

    /// Runs — or resumes — a deletion from whatever phase it is recorded at.
    private func runHouseholdDeletion(_ recorded: HouseholdLifecycleTransition,
                                      for session: AccountSession) async -> Bool {
        guard let sharing, let transitions else { return false }
        var transition = recorded
        let context = session.context
        let persistence = session.persistence
        let source = transition.sourceHouseholdID

        do {
            switch transition.kind {
            case .deleteShared:
                try await tasks.run(context: context) {
                    // No copy: this deletes the fridge for every member, which
                    // is exactly what the confirmation said.
                    _ = try await sharing.purgeZone(of: source, in: .privateDatabase)
                    try await persistence.ensureLocalGraphAbsent(of: source)
                }

            case .deletePrivate:
                if transition.phase == .privateDeletePrepared {
                    // Idempotent: already absent simply advances the phase.
                    try await tasks.run(context: context) {
                        try await persistence.ensureLocalGraphAbsent(of: source)
                    }
                    transition.phase = .privateDeleteAwaitingCloud
                    transitions.save(transition)
                    applyTransitionPhase(transition, for: context)
                    // The user gets their fallback fridge now; only the claim
                    // that iCloud is finished has to wait.
                    await finishHouseholdRemoval(source, for: context, controller: persistence)
                }

                guard try await confirmCloudDeletion(of: transition, sharing: sharing,
                                                     context: context)
                else {
                    householdFailure = HouseholdActionFailure(
                        reason: .unavailable,
                        message: "Still removing this fridge from iCloud. Tridge will finish it.",
                        diagnosticID: "delete.awaitingCloud")
                    return false
                }

            case .stopSharing, .recoverOwnedZone:
                return false
            }
        } catch is AccountTaskRegistry.Rejection {
            return false
        } catch {
            inventory?.reopenCommandAdmission()
            householdFailure = HouseholdActionFailure(error, stage: "delete")
            applySuppression(of: transition)
            return false
        }

        transitions.clear()
        pendingLifecycleTransition = nil
        if transition.kind == .deleteShared {
            await finishHouseholdRemoval(source, for: context, controller: persistence)
        } else {
            inventory?.reopenCommandAdmission()
        }
        return true
    }

    /// Waits for the next successful private-store export, then reads the
    /// captured records back.
    ///
    /// The export event alone is not confirmation — it says work was sent, not
    /// that these records are gone — so completion requires every captured id
    /// to come back unknown-item.
    private func confirmCloudDeletion(of transition: HouseholdLifecycleTransition,
                                      sharing: any HouseholdSharing,
                                      context: AccountSessionContext) async throws -> Bool {
        let captured = transition.capturedRecords
        // Nothing was ever mirrored, so the verified local save is the whole
        // deletion.
        guard !captured.isEmpty else { return true }

        let exported = await syncMonitor.waitForNextSuccessfulExport(
            generation: context.generation, storeIdentifier: context.privateStoreIdentifier)
        guard exported else { return false }
        return try await tasks.run(context: context) {
            try await sharing.confirmRecordsAbsent(captured)
        }
    }

    // MARK: - Leaving and losing access

    /// A member leaves a received Household.
    ///
    /// It makes no private copy and cannot delete the owner's share or zone: it
    /// removes this member's participation and their local mirror, and says so.
    @discardableResult
    func leaveHousehold(_ householdID: UUID) async -> Bool {
        await runHouseholdAction {
            guard let household = self.households.first(where: { $0.id == householdID }),
                  household.ownership == .received
            else {
                self.householdFailure = HouseholdActionFailure(
                    reason: .householdUnavailable,
                    message: "That fridge isn't available on this device any more.",
                    diagnosticID: "leave.household")
                return false
            }
            return await self.removeReceivedHousehold(householdID, stage: "leave")
        }
    }

    /// CloudKit refused a write to a received Household: the member's access is
    /// gone.
    ///
    /// The Household disappears from normal interaction at once — before any
    /// purge is attempted — so nothing keeps offering a fridge that can no
    /// longer be opened.
    func handleLostAccess(to householdID: UUID) {
        // Owned Households are never cleaned up on a refused write: an owner
        // losing permission to their own fridge is a recovery case, not a
        // reason to delete their only copy.
        guard households.contains(where: { $0.id == householdID && $0.ownership == .received })
        else {
            if let session { refreshShareState(for: session.context) }
            return
        }
        suppressedHouseholdIDs.insert(householdID)
        households.removeAll { $0.id == householdID }
        Task { [weak self] in
            guard let self else { return }
            await self.runHouseholdAction {
                await self.removeReceivedHousehold(householdID, stage: "accessLost")
            }
        }
    }

    /// Purges the member's shared-zone objects, verifies local absence, and
    /// falls back.
    ///
    /// A server zone that is already missing is a cleanup path, not success:
    /// whatever is still local is deleted and verified absent before this
    /// reports completion.
    private func removeReceivedHousehold(_ householdID: UUID, stage: String) async -> Bool {
        guard let session, let sharing else { return false }
        householdFailure = nil
        suppressedHouseholdIDs.insert(householdID)
        households.removeAll { $0.id == householdID }

        let context = session.context
        let persistence = session.persistence
        if inventory?.householdID == householdID {
            await inventory?.closeCommandAdmission()
        }

        do {
            try await tasks.run(context: context) {
                _ = try await sharing.purgeZone(of: householdID, in: .sharedDatabase)
                try await persistence.ensureLocalGraphAbsent(of: householdID)
            }
        } catch is AccountTaskRegistry.Rejection {
            return false
        } catch {
            // The Household stays hidden and the failure stays retryable; no
            // stale inventory is exposed in the meantime.
            inventory?.reopenCommandAdmission()
            householdFailure = HouseholdActionFailure(error, stage: stage)
            return false
        }

        await finishHouseholdRemoval(householdID, for: context, controller: persistence)
        return true
    }

    /// Retires the removed Household's local effects and picks a replacement.
    private func finishHouseholdRemoval(_ householdID: UUID,
                                        for context: AccountSessionContext,
                                        controller: PersistenceController) async {
        guard currentGeneration == context.generation else { return }
        await reminders.retire(scope: .household(accountScope: context.accountScope.value,
                                                 householdID: householdID))
        if activeHouseholdID == householdID { activeHouseholdID = nil }
        inventory?.reopenCommandAdmission()
        selectActiveHousehold(for: context, controller: controller)
    }

    // MARK: - Remote history

    /// Brings up this generation's history consumer and starts observing remote
    /// changes for its two stores.
    ///
    /// The first pass runs immediately: an import can complete between the
    /// store load and this point, and its notification would already be gone.
    private func startHistoryProcessing(for context: AccountSessionContext,
                                        controller: PersistenceController) {
        let reconciler = DuplicateReconciler(persistence: controller)
        let processor = PersistentHistoryProcessor(
            persistence: controller,
            tokens: HistoryTokenStore(accountScope: context.accountScope, defaults: defaults),
            effects: HistoryEffects(
                reconcileDuplicates: { householdID in
                    _ = try await reconciler.reconcile(householdID: householdID,
                                                       today: InventoryDay.today())
                },
                refreshSession: { [weak self] householdIDs in
                    await self?.applyImportedChanges(householdIDs, for: context)
                }))
        history = processor
        observeRemoteChanges(for: context, controller: controller)
        processHistory(for: context, storeURL: nil)
    }

    private func observeRemoteChanges(for context: AccountSessionContext,
                                      controller: PersistenceController) {
        remoteChangeObserver.register {
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: controller.container.persistentStoreCoordinator, queue: .main
            ) { [weak self] notification in
                let storeURL = notification.userInfo?[NSPersistentStoreURLKey] as? URL
                MainActor.assumeIsolated {
                    self?.processHistory(for: context, storeURL: storeURL)
                }
            }
        }
    }

    /// Registered like every other account-bound operation, so a drain waits
    /// for a pass that is already merging before its stores are removed.
    private func processHistory(for context: AccountSessionContext, storeURL: URL?) {
        guard currentGeneration == context.generation, let history else { return }
        let tasks = self.tasks
        Task {
            _ = try? await tasks.run(context: context) {
                await history.process(storeURL: storeURL)
            }
        }
    }

    /// Foreground activation: report local truth rather than pretending to
    /// force a sync. `NSPersistentCloudKitContainer` keeps importing on its own;
    /// this only makes sure whatever already landed has been consumed.
    func refreshOnForeground() {
        guard let session else { return }
        processHistory(for: session.context, storeURL: nil)
        // Share changes are refreshed on their own path, because they never
        // produce a persistent-history transaction to notice.
        refreshShareState(for: session.context)
    }

    /// The main-actor apply boundary for an import: a batch processed for the
    /// previous account is dropped here even though its pass was already
    /// running when the account changed.
    private func applyImportedChanges(_ householdIDs: Set<UUID>,
                                      for context: AccountSessionContext) async {
        guard currentGeneration == context.generation, let session,
              session.context.generation == context.generation
        else { return }

        // A Household may have arrived, been renamed, or gone away, so the
        // deterministic selection runs again before the inventory is re-read.
        selectActiveHousehold(for: context, controller: session.persistence)
        guard let inventory, householdIDs.contains(inventory.householdID) else { return }
        reloadInventory()
    }

    /// Retires the previous account's reminders when the account really
    /// changed — or when there is no account any more, so a signed-out
    /// installation stops notifying about a fridge it cannot open.
    ///
    /// A Retry for the same account is deliberately not a transition: wiping
    /// and rebuilding its own schedule would only make reminders flicker.
    private func retireRemindersOfPreviousAccount(replacedBy scope: AccountScopeHash?) async {
        guard let previous = lastValidatedScope, previous != scope else { return }
        await reminders.retire(scope: .account(previous.value))
        reminders.clearBadge()
        lastValidatedScope = nil
    }

    // MARK: - Bootstrap gate

    private func applyBootstrapGate(for context: AccountSessionContext,
                                    controller: PersistenceController) {
        hasCompletedInitialPrivateImport = barrier.hasCompletedInitialImport(
            accountScope: context.accountScope,
            privateStoreIdentifier: context.privateStoreIdentifier)

        // Before normal selection: a Household part-way through a copy or a
        // purge must never be offered as somewhere to put groceries.
        let transition = transitions?.current()
        pendingLifecycleTransition = transition
        if let transition {
            suppressedHouseholdIDs.formUnion(transition.suppressedHouseholdIDs)
        }

        selectActiveHousehold(for: context, controller: controller)

        if !hasCompletedInitialPrivateImport {
            watchInitialImport(for: context)
        }
        if let transition {
            resume(transition, for: context, controller: controller)
        }
    }

    /// Runs the deterministic fallback and settles the launch state.
    ///
    /// An existing cache resolves at step 1–3 and renders immediately; only a
    /// cache with nothing to select waits, because creating `My Fridge` while
    /// this account's household may still be importing is what would duplicate
    /// it. Re-run whenever the set of accessible Households changes.
    private func selectActiveHousehold(for context: AccountSessionContext,
                                       controller: PersistenceController) {
        let (available, issues) = controller.householdSnapshots()
        // A suppression lasts exactly as long as the record it hides: once the
        // graph is really gone, a later re-invitation is free to bring it back.
        suppressedHouseholdIDs.formIntersection(Set(available.map(\.id)))
        households = available
            .filter { !suppressedHouseholdIDs.contains($0.id) }
            .map { $0.withShareState(isShared: sharedHouseholdIDs.contains($0.id)) }
        refreshShareState(for: context)
        // A share title that could not be written survives termination, so the
        // marker is re-read whenever the accessible set changes.
        householdsWithStaleShareTitle = Set(
            households.map(\.id).filter { shareTitles?.needsRetry($0) ?? false })
        for issue in issues {
            AppLog.household.error("Omitted a corrupt record: \(issue.diagnosticDescription)")
        }

        switch HouseholdSelection.choose(
            saved: activeHouseholds.savedID(for: context.accountScope),
            available: available,
            hasCompletedInitialImport: hasCompletedInitialPrivateImport
        ) {
        case .select(let id):
            activate(householdID: id, for: context, controller: controller)
        case .createDefaultHousehold:
            createDefaultHousehold(for: context, controller: controller)
        case .waitForInitialImport:
            activeHouseholdID = nil
            launchState = .finishingCloudSetup
            return
        }

        startLegacyUpgradeIfNeeded(for: context, controller: controller)
    }

    private func activate(householdID: UUID, for context: AccountSessionContext,
                          controller: PersistenceController) {
        activeHouseholdID = householdID
        activeHouseholds.save(householdID, for: context.accountScope)
        launchState = .ready
        openInventory(householdID: householdID, for: context, controller: controller)
    }

    /// Brings up — or re-points — the value-snapshot session Home reads from.
    ///
    /// One session per generation: switching Households re-points the existing
    /// one, so a command already in flight is applied against the fridge it was
    /// issued for or dropped, never redirected into another.
    private func openInventory(householdID: UUID, for context: AccountSessionContext,
                               controller: PersistenceController) {
        if let inventory {
            guard inventory.householdID != householdID else { return }
            inventoryTask?.cancel()
            inventoryTask = Task { await inventory.select(householdID: householdID) }
            return
        }

        let session = HouseholdSession(
            householdID: householdID,
            accountContext: context,
            repository: CoreDataInventoryRepository(persistence: controller),
            reconciler: DuplicateReconciler(persistence: controller),
            tasks: tasks, reminders: reminders)
        // A refused write is how a member learns their access is gone; the
        // coordinator turns that into local cleanup and a fallback.
        session.onAccessLost = { [weak self] id in self?.handleLostAccess(to: id) }
        inventory = session
        // The work itself registers with the task registry; this handle only
        // exists so an account change stops awaiting it.
        inventoryTask = Task { await session.load() }
    }

    /// Re-reads the Active Household's snapshots and persists the merge claims
    /// they imply, behind whatever the session is already doing: a reload that
    /// overtook the first load would leave the older, emptier projection on
    /// screen.
    private func reloadInventory() {
        guard let inventory else { return }
        let previous = inventoryTask
        inventoryTask = Task {
            await previous?.value
            await inventory.load()
        }
    }

    private func createDefaultHousehold(for context: AccountSessionContext,
                                        controller: PersistenceController) {
        do {
            let created = try controller.createOwnedHousehold(
                named: HouseholdSelection.defaultHouseholdName)
            // Reached only when nothing was selectable, so this is the set.
            households = [created]
            activate(householdID: created.id, for: context, controller: controller)
        } catch {
            // The stores opened but the account has no usable Household, so
            // there is nothing to show. Retry rebuilds the stack.
            launchState = .persistenceUnavailable(diagnosticID: "household.create")
        }
    }

    // MARK: - Upgrade from the shipping build

    /// Acknowledges the one-time migration notice. Recorded separately from the
    /// migration itself, so terminating before this shows the notice again.
    func acknowledgeMigrationNotice() {
        upgrade.acknowledgeNotice()
        showsMigrationNotice = false
    }

    /// Retries a migration that failed. The archive is untouched, so this is
    /// simply the same attempt again.
    func retryLegacyMigration() {
        guard let session else { return }
        legacyMigrationFailure = nil
        startLegacyUpgradeIfNeeded(for: session.context, controller: session.persistence)
    }

    /// Moves the archived inventory into this account's own fridge, once.
    ///
    /// Ordering matters twice over: the destination must be an owned Household,
    /// never one received through someone else's share, and creating that
    /// Household is only safe once the bootstrap barrier has proven the account
    /// does not already own one that is still importing.
    private func startLegacyUpgradeIfNeeded(for context: AccountSessionContext,
                                            controller: PersistenceController) {
        guard launchState == .ready, upgradeTask == nil, legacyMigrationFailure == nil else {
            return
        }
        guard upgrade.isPending else {
            upgrade.recordCompletionIfFinished()
            return
        }
        guard let destination = migrationDestination(controller: controller) else { return }

        upgradeTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.runMigration(into: destination, for: context,
                                                 controller: controller)
            self.applyMigration(result, for: context)
        }
    }

    /// The account's first owned Household, creating `My Fridge` when the
    /// account owns none. Nil while that cannot be decided yet.
    private func migrationDestination(controller: PersistenceController) -> UUID? {
        if let owned = HouseholdSelection.oldestOwned(in: households) { return owned.id }
        // Only received Households are accessible. Creating the destination has
        // to wait for the same evidence bootstrap waits for, or an owned
        // Household still arriving in the first import would be duplicated.
        guard hasCompletedInitialPrivateImport else { return nil }
        do {
            let created = try controller.createOwnedHousehold(
                named: HouseholdSelection.defaultHouseholdName)
            // Visible in the picker, but not selected: an upgrade never
            // silently switches the fridge the user is looking at.
            households.append(created)
            return created.id
        } catch {
            legacyMigrationFailure = LegacyMigrationFailure(diagnosticID: "legacy.household")
            return nil
        }
    }

    private func runMigration(into destination: UUID, for context: AccountSessionContext,
                              controller: PersistenceController)
    async -> Result<Int, LegacyMigrationFailure>? {
        // Copied out before the closure so the read and the write run off the
        // main actor rather than hopping back for every property access.
        let upgrade = self.upgrade
        do {
            let migrated = try await tasks.run(context: context) {
                try await upgrade.migrate(into: destination,
                                          accountScope: context.accountScope,
                                          using: controller)
            }
            return .success(migrated)
        } catch let failure as LegacyMigrationFailure {
            return .failure(failure)
        } catch {
            // The account changed while this was starting or running; the
            // transition that invalidated the generation owns the state now.
            return nil
        }
    }

    /// The main-actor apply boundary: a migration that finished for the previous
    /// account never touches this one's state.
    private func applyMigration(_ result: Result<Int, LegacyMigrationFailure>?,
                                for context: AccountSessionContext) {
        // Cleared only for the generation that owns it: a stale apply must not
        // release the slot the current generation's migration is running in.
        guard let result, currentGeneration == context.generation else { return }
        upgradeTask = nil
        switch result {
        case .success(let migrated):
            AppLog.household.info("Migrated \(migrated) legacy rows")
            upgrade.recordCompletionIfFinished()
            showsMigrationNotice = upgrade.needsNotice
            // The session opened alongside the migration, so its first
            // projection can already have read the destination while it was
            // still empty. Nothing else writes to a Household from outside the
            // session, so this is the one place that has to re-read — and it
            // reloads rather than only reading, because a migrated root can
            // share a name with one already in the Household and that link is
            // permanent only once the reconciler has written it (ADR 0006).
            reloadInventory()
        case .failure(let failure):
            // The archive is intact and the stores are fine, so this is a
            // retryable notice rather than a launch state.
            AppLog.household.error("Legacy migration failed: \(failure.diagnosticID)")
            legacyMigrationFailure = failure
        }
    }

    private func watchInitialImport(for context: AccountSessionContext) {
        barrierWatch?.cancel()
        barrierWatch = Task { [weak self] in
            guard let self else { return }
            let opened = await self.awaitInitialImport(for: context)
            self.applyInitialImport(opened, for: context)
        }
    }

    private func awaitInitialImport(for context: AccountSessionContext) async -> Bool {
        let opened = try? await tasks.run(context: context) { [weak self] in
            guard let self else { return false }
            return await self.syncMonitor.waitForInitialImport(
                generation: context.generation,
                storeIdentifier: context.privateStoreIdentifier)
        }
        return opened ?? false
    }

    /// The main-actor apply boundary: a barrier that opened for the previous
    /// account is dropped here even though its wait was already running when
    /// the account changed.
    private func applyInitialImport(_ opened: Bool, for context: AccountSessionContext) {
        guard opened, currentGeneration == context.generation else { return }
        barrier.recordInitialImport(accountScope: context.accountScope,
                                    privateStoreIdentifier: context.privateStoreIdentifier)
        hasCompletedInitialPrivateImport = true
        guard let session, session.context.generation == context.generation else { return }
        // The import may have brought this account's existing Household with
        // it, so selection runs again rather than assuming an empty cache.
        selectActiveHousehold(for: context, controller: session.persistence)
    }
}
