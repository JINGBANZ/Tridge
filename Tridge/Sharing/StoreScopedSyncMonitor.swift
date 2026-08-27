import CloudKit
import CoreData
import Foundation
import Network

/// Overall sync health for exactly one account session.
///
/// The session methods exist because CloudKit events outlive the account that
/// produced them: observation must be installed before a store can start
/// setup, and a completion that arrives after the account changed must not
/// settle the new account's state.
@MainActor
protocol SyncStatusProviding: AnyObject {
    var currentStatus: SyncStatus { get }
    /// A new stream per caller, seeded with the current status.
    var statusUpdates: AsyncStream<SyncStatus> { get }

    /// The account coordinator is authoritative for whether the account itself
    /// permits syncing; the monitor only reports it.
    func updateAccountState(_ state: SyncAccountState)

    /// Starts observing before `loadPersistentStores`, so setup and import
    /// events emitted during the load are buffered rather than lost.
    func prepareSession(generation: AccountGeneration)
    /// Narrows observation to the two identifiers that actually opened.
    func activateSession(generation: AccountGeneration, storeIdentifiers: Set<String>)
    /// Clears every buffered and in-flight event owned by that generation.
    func endSession(generation: AccountGeneration)

    /// The bootstrap barrier for one store in the current session.
    func hasCompletedInitialImport(generation: AccountGeneration,
                                   storeIdentifier: String) -> Bool
    /// Resolves true when the barrier opens, or false if the session ends,
    /// the account changes, or the caller is cancelled first.
    func waitForInitialImport(generation: AccountGeneration,
                              storeIdentifier: String) async -> Bool

    /// Resolves true when a successful export completes for this store *after*
    /// this call, or false if the session ends, the account changes, or the
    /// caller is cancelled first.
    ///
    /// The verified-deletion path needs the next export after its own save; an
    /// export that already happened proves nothing about it.
    func waitForNextSuccessfulExport(generation: AccountGeneration,
                                     storeIdentifier: String) async -> Bool

    /// Called when this session's events show that a zone was deleted or the
    /// account's encryption key was reset, with the store it happened to.
    ///
    /// A closure rather than a status: recovery is a decision the coordinator
    /// takes once, not a state the screen polls.
    var onRecoveryNeeded: ((SyncRecoveryNeed, String) -> Void)? { get set }
}

/// Reduces `NSPersistentCloudKitContainer` events into sync state for the
/// current session's two stores only.
///
/// It deliberately has no say in whether stores may open or writes may proceed
/// — that stays with `AccountSessionCoordinator`. What it owns is the claim
/// that a given event belongs to this account's stores, which is why every
/// event passes through the generation guard here and the store guard in
/// `SyncSessionReducer`.
@MainActor
final class StoreScopedSyncMonitor: SyncStatusProviding {
    private struct ImportWaiter {
        let id: UUID
        let generation: AccountGeneration
        let storeIdentifier: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Waits for the export count of one store to move past what it was when
    /// the wait started.
    private struct ExportWaiter {
        let id: UUID
        let generation: AccountGeneration
        let storeIdentifier: String
        let baseline: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var generation: AccountGeneration?
    private var reducer = SyncSessionReducer()
    private var accountState: SyncAccountState = .validated
    private var isNetworkReachable = true
    /// Both are held in objects whose own `deinit` may clean them up: a
    /// nonisolated `deinit` here could not touch main-actor state, and leaving
    /// either behind means a dangling observer or a consumer that never
    /// finishes iterating.
    private let eventObserver = NotificationObserverToken()
    private let statusStreams = StatusStreamRegistry()
    private var pathMonitor: NWPathMonitor?
    private var importWaiters: [ImportWaiter] = []
    private var exportWaiters: [ExportWaiter] = []

    private(set) var currentStatus: SyncStatus = .syncing
    var onRecoveryNeeded: ((SyncRecoveryNeed, String) -> Void)?
    /// One report per store per session: the container retries a failing zone
    /// repeatedly, and the user should be asked once.
    private var reportedRecoveries: Set<String> = []

    init() {
        startPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    var statusUpdates: AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        let id = statusStreams.add(continuation)
        continuation.yield(currentStatus)
        // Weak: the registry owns the continuation, which owns this closure.
        // A strong capture would keep the registry alive forever and its
        // `deinit` — the thing that finishes the streams — could never run.
        continuation.onTermination = { [weak statusStreams] _ in statusStreams?.remove(id) }
        return stream
    }

    // MARK: - Session lifecycle

    func updateAccountState(_ state: SyncAccountState) {
        accountState = state
        refreshStatus()
    }

    func prepareSession(generation: AccountGeneration) {
        // A prepare without a matching end means the previous attempt failed;
        // release its waiters rather than stranding them.
        resumeAllWaiters(with: false)
        self.generation = generation
        reducer = SyncSessionReducer()
        reportedRecoveries = []
        installEventObserver()
        refreshStatus()
    }

    func activateSession(generation: AccountGeneration, storeIdentifiers: Set<String>) {
        guard generation == self.generation else { return }
        reducer.activate(storeIdentifiers: storeIdentifiers)
        resolveImportWaiters()
        resolveExportWaiters()
        refreshStatus()
    }

    func endSession(generation: AccountGeneration) {
        guard generation == self.generation else { return }
        self.generation = nil
        reducer = SyncSessionReducer()
        reportedRecoveries = []
        eventObserver.remove()
        resumeAllWaiters(with: false)
        refreshStatus()
    }

    // MARK: - Events

    /// The single entry point for events, whether they arrive from the
    /// notification or from a test.
    func receive(_ event: SyncEvent) {
        guard generation != nil else { return }
        reducer.record(event)
        resolveImportWaiters()
        resolveExportWaiters()
        reportRecoveryIfNeeded(event)
        refreshStatus()
    }

    /// Reports a recovery need for a store this session actually opened.
    private func reportRecoveryIfNeeded(_ event: SyncEvent) {
        guard let recovery = event.recovery, event.isComplete, !event.succeeded,
              reducer.isActiveStore(event.storeIdentifier)
        else { return }
        let key = "\(event.storeIdentifier).\(recovery.rawValue)"
        guard reportedRecoveries.insert(key).inserted else { return }
        onRecoveryNeeded?(recovery, event.storeIdentifier)
    }

    private func installEventObserver() {
        guard !eventObserver.isRegistered else { return }
        eventObserver.register {
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event,
                    let syncEvent = SyncEvent(event) else { return }
                MainActor.assumeIsolated { self?.receive(syncEvent) }
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            Task { @MainActor in self?.updateReachability(isReachable) }
        }
        monitor.start(queue: DispatchQueue(label: "com.tridge.sync.path"))
        pathMonitor = monitor
    }

    private func updateReachability(_ isReachable: Bool) {
        guard isNetworkReachable != isReachable else { return }
        isNetworkReachable = isReachable
        refreshStatus()
    }

    private func refreshStatus() {
        let status = reducer.status(account: accountState,
                                    isNetworkReachable: isNetworkReachable)
        guard status != currentStatus else { return }
        currentStatus = status
        statusStreams.yield(status)
    }

    // MARK: - Bootstrap barrier

    func hasCompletedInitialImport(generation: AccountGeneration,
                                   storeIdentifier: String) -> Bool {
        guard generation == self.generation else { return false }
        return reducer.hasCompletedInitialImport(storeIdentifier: storeIdentifier)
    }

    func waitForInitialImport(generation: AccountGeneration,
                              storeIdentifier: String) async -> Bool {
        guard generation == self.generation else { return false }
        if reducer.hasCompletedInitialImport(storeIdentifier: storeIdentifier) { return true }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                importWaiters.append(ImportWaiter(id: id, generation: generation,
                                                  storeIdentifier: storeIdentifier,
                                                  continuation: continuation))
            }
        } onCancel: {
            // The registry cancels this wait when the account changes, so it
            // must not outlive the drain that is waiting for it.
            Task { @MainActor [weak self] in self?.resumeWaiter(id, with: false) }
        }
    }

    func waitForNextSuccessfulExport(generation: AccountGeneration,
                                     storeIdentifier: String) async -> Bool {
        guard generation == self.generation else { return false }
        let baseline = reducer.successfulExportCount(storeIdentifier: storeIdentifier)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                exportWaiters.append(ExportWaiter(id: id, generation: generation,
                                                  storeIdentifier: storeIdentifier,
                                                  baseline: baseline,
                                                  continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeExportWaiter(id, with: false) }
        }
    }

    private func resolveExportWaiters() {
        guard let generation else { return }
        let resolved = exportWaiters.filter {
            $0.generation == generation
                && reducer.successfulExportCount(storeIdentifier: $0.storeIdentifier) > $0.baseline
        }
        guard !resolved.isEmpty else { return }
        let resolvedIDs = Set(resolved.map(\.id))
        exportWaiters.removeAll { resolvedIDs.contains($0.id) }
        for waiter in resolved { waiter.continuation.resume(returning: true) }
    }

    private func resumeExportWaiter(_ id: UUID, with value: Bool) {
        guard let index = exportWaiters.firstIndex(where: { $0.id == id }) else { return }
        exportWaiters.remove(at: index).continuation.resume(returning: value)
    }

    private func resolveImportWaiters() {
        guard let generation else { return }
        let resolved = importWaiters.filter {
            $0.generation == generation
                && reducer.hasCompletedInitialImport(storeIdentifier: $0.storeIdentifier)
        }
        guard !resolved.isEmpty else { return }
        let resolvedIDs = Set(resolved.map(\.id))
        importWaiters.removeAll { resolvedIDs.contains($0.id) }
        for waiter in resolved { waiter.continuation.resume(returning: true) }
    }

    private func resumeWaiter(_ id: UUID, with value: Bool) {
        guard let index = importWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = importWaiters.remove(at: index)
        waiter.continuation.resume(returning: value)
    }

    private func resumeAllWaiters(with value: Bool) {
        let waiters = importWaiters
        importWaiters = []
        for waiter in waiters { waiter.continuation.resume(returning: value) }

        let exports = exportWaiters
        exportWaiters = []
        for waiter in exports { waiter.continuation.resume(returning: value) }
    }
}

extension SyncEvent {
    /// Keeps only what decides state. Timestamps stay behind: the store
    /// identifier and the recorded start are the isolation boundary, and a
    /// clock comparison would be a weaker one.
    init?(_ event: NSPersistentCloudKitContainer.Event) {
        guard let kind = SyncEventKind(event.type) else { return nil }
        // The event id is a UUID and the store id a string; the reducer only
        // ever compares them, so one opaque key type keeps it simple.
        self.init(identifier: event.identifier.uuidString,
                  storeIdentifier: event.storeIdentifier,
                  kind: kind,
                  isComplete: event.endDate != nil,
                  succeeded: event.succeeded,
                  isTransientFailure: Self.isTransientFailure(event.error),
                  recovery: Self.recoveryNeed(event.error))
    }

    /// Distinguishes a deleted zone from an encrypted-data-key reset.
    ///
    /// Apple reports the reset as a zone-not-found error carrying
    /// `CKErrorUserDidResetEncryptedDataKey` in its `userInfo`, so the flag is
    /// checked first — otherwise a key rotation would be reported to the user
    /// as somebody having deleted their data.
    static func recoveryNeed(_ error: Error?) -> SyncRecoveryNeed? {
        guard let error = error as? CKError else { return nil }
        if error.userInfo[CKErrorUserDidResetEncryptedDataKey] != nil {
            return .encryptionKeyReset
        }
        switch error.code {
        case .userDeletedZone, .zoneNotFound: return .zoneDeleted
        default: return nil
        }
    }

    /// A failure the system retries by itself — lost connectivity, throttling,
    /// a busy zone — must not be reported as something the user has to fix.
    /// Anything else, including a TLS or certificate failure, is permanent
    /// until something changes, so it surfaces as `needsAttention`.
    static func isTransientFailure(_ error: Error?) -> Bool {
        guard let error else { return false }
        let details = error as NSError
        switch details.domain {
        case CKErrorDomain:
            return Self.retriedCloudKitCodes.contains(details.code)
        case NSURLErrorDomain:
            return Self.retriedURLCodes.contains(details.code)
        default:
            return false
        }
    }

    private static let retriedCloudKitCodes: Set<Int> = [
        CKError.Code.networkUnavailable.rawValue,
        CKError.Code.networkFailure.rawValue,
        CKError.Code.serviceUnavailable.rawValue,
        CKError.Code.requestRateLimited.rawValue,
        CKError.Code.zoneBusy.rawValue,
    ]

    private static let retriedURLCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
    ]
}

extension SyncEventKind {
    init?(_ type: NSPersistentCloudKitContainer.EventType) {
        switch type {
        case .setup: self = .setup
        case .`import`: self = .importChanges
        case .export: self = .exportChanges
        @unknown default: return nil
        }
    }
}

/// Holds the status-stream continuations and finishes them when the monitor is
/// released, so a consumer iterating `statusUpdates` cannot hang forever on a
/// stream nobody will ever yield to again.
private final class StatusStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    func add(_ continuation: AsyncStream<SyncStatus>.Continuation) -> UUID {
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        return id
    }

    func remove(_ id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }

    func yield(_ status: SyncStatus) {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current { continuation.yield(status) }
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }
}
