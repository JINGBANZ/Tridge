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

    let tasks: AccountTaskRegistry
    let syncMonitor: any SyncStatusProviding

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
    private let makePersistence: @Sendable (AccountScopeHash) async throws -> PersistenceController

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

    init(identity: any AccountIdentityProviding = CloudKitAccountIdentity(),
         syncMonitor: any SyncStatusProviding,
         tasks: AccountTaskRegistry = AccountTaskRegistry(),
         reminders: ReminderReconciler = ReminderReconciler(),
         defaults: UserDefaults = .standard,
         barrier: BootstrapBarrierStore = BootstrapBarrierStore(),
         activeHouseholds: ActiveHouseholdStore = ActiveHouseholdStore(),
         upgrade: LegacyInventoryUpgrade = LegacyInventoryUpgrade(),
         makePersistence: @escaping @Sendable (AccountScopeHash) async throws
             -> PersistenceController = AccountSessionCoordinator.loadCloudKitStack) {
        self.identity = identity
        self.reminders = reminders
        self.defaults = defaults
        self.syncMonitor = syncMonitor
        self.tasks = tasks
        self.barrier = barrier
        self.activeHouseholds = activeHouseholds
        self.upgrade = upgrade
        self.makePersistence = makePersistence
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
        applyBootstrapGate(for: context, controller: controller)
        startHistoryProcessing(for: context, controller: controller)
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

        selectActiveHousehold(for: context, controller: controller)

        if !hasCompletedInitialPrivateImport {
            watchInitialImport(for: context)
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
        households = available
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
