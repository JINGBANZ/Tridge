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

    let tasks: AccountTaskRegistry
    let syncMonitor: any SyncStatusProviding

    private let identity: any AccountIdentityProviding
    private let barrier: BootstrapBarrierStore
    private let makePersistence: @Sendable (AccountScopeHash) async throws -> PersistenceController

    /// The coordinator's own mirror of the registry's open generation. Work
    /// applying its result on the main actor checks this, so a value produced
    /// for the previous account cannot land on the current one.
    private var currentGeneration: AccountGeneration?
    private var accountObserver: NSObjectProtocol?
    private var transitionTask: Task<Void, Never>?
    private var barrierWatch: Task<Void, Never>?

    init(identity: any AccountIdentityProviding = CloudKitAccountIdentity(),
         syncMonitor: any SyncStatusProviding,
         tasks: AccountTaskRegistry = AccountTaskRegistry(),
         barrier: BootstrapBarrierStore = BootstrapBarrierStore(),
         makePersistence: @escaping @Sendable (AccountScopeHash) async throws
             -> PersistenceController = AccountSessionCoordinator.loadCloudKitStack) {
        self.identity = identity
        self.syncMonitor = syncMonitor
        self.tasks = tasks
        self.barrier = barrier
        self.makePersistence = makePersistence
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
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
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountDidChange() }
        }
    }

    /// The account changed: rebuild everything under a new generation. Queued
    /// behind any transition already running, so two notifications cannot tear
    /// down the same stack twice.
    func accountDidChange() {
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

    /// The account transition, in the order the stores require: invalidate and
    /// close admission, close inventory UI, drain every registered operation,
    /// end sync observation, and only then release the stores.
    private func invalidateCurrentSession() async {
        let previousGeneration = currentGeneration
        currentGeneration = nil
        await tasks.close()

        launchState = .preparing
        let previousSession = session
        session = nil
        hasCompletedInitialPrivateImport = false
        barrierWatch?.cancel()
        barrierWatch = nil

        await tasks.cancelAndDrain()

        if let previousGeneration {
            syncMonitor.endSession(generation: previousGeneration)
        }
        previousSession?.persistence.tearDown()
    }

    private func validateAndLoad() async {
        let accountScope: AccountScopeHash
        do {
            accountScope = try await identity.validateCurrentAccountScope()
        } catch let error as AccountIdentityError {
            syncMonitor.updateAccountState(.unavailable)
            launchState = LaunchState(accountError: error)
            return
        } catch {
            // An unmodelled failure is undetermined, not signed out: a cold
            // launch retries rather than guessing which account it is.
            syncMonitor.updateAccountState(.unavailable)
            launchState = .iCloudAccountRequired(.couldNotDetermine)
            return
        }

        syncMonitor.updateAccountState(.validated)
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
    }

    // MARK: - Bootstrap gate

    private func applyBootstrapGate(for context: AccountSessionContext,
                                    controller: PersistenceController) {
        hasCompletedInitialPrivateImport = barrier.hasCompletedInitialImport(
            accountScope: context.accountScope,
            privateStoreIdentifier: context.privateStoreIdentifier)

        // A cache that already holds a household renders immediately: selection
        // resolves it without ever reaching the create-`My Fridge` fallback.
        launchState = hasCompletedInitialPrivateImport || hasAnyHousehold(in: controller)
            ? .ready : .finishingCloudSetup

        if !hasCompletedInitialPrivateImport {
            watchInitialImport(for: context)
        }
    }

    private func hasAnyHousehold(in controller: PersistenceController) -> Bool {
        let request = HouseholdRecord.fetchRequest()
        request.fetchLimit = 1
        let households = (try? controller.viewContext.fetch(request)) ?? []
        return !households.isEmpty
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
        if launchState == .finishingCloudSetup { launchState = .ready }
    }
}
