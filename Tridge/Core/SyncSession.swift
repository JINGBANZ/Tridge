import Foundation

/// The four states the Household screen can show. Diagnostic only: none of them
/// claims that another device has already received a change.
public enum SyncStatus: Equatable, Sendable {
    case upToDate
    case syncing
    case offline
    case needsAttention
}

/// The three kinds of work `NSPersistentCloudKitContainer` reports.
public enum SyncEventKind: Equatable, Hashable, Sendable {
    case setup
    case importChanges
    case exportChanges
}

/// Whether the account itself permits syncing. The account coordinator is
/// authoritative here; the monitor only reports what it is told.
public enum SyncAccountState: Equatable, Sendable {
    case validated
    case unavailable
}

/// One `NSPersistentCloudKitContainer.Event` reduced to the facts that decide
/// sync state. Timestamps are deliberately absent: the store identifier and the
/// recorded start are the isolation boundary, never the clock.
public struct SyncEvent: Equatable, Sendable {
    public let identifier: String
    public let storeIdentifier: String
    public let kind: SyncEventKind
    /// False while the event is still running; true once it has an end date.
    public let isComplete: Bool
    public let succeeded: Bool
    /// A failed event that only lost the network. It is expected to retry, so
    /// it never becomes `needsAttention`.
    public let isNetworkFailure: Bool

    public init(identifier: String, storeIdentifier: String, kind: SyncEventKind,
                isComplete: Bool, succeeded: Bool = false, isNetworkFailure: Bool = false) {
        self.identifier = identifier
        self.storeIdentifier = storeIdentifier
        self.kind = kind
        self.isComplete = isComplete
        self.succeeded = succeeded
        self.isNetworkFailure = isNetworkFailure
    }
}

/// Reduces one account session's CloudKit events into sync state.
///
/// The reducer is created when a generation is prepared and thrown away when it
/// ends, so "belongs to the current generation" is enforced by its lifetime.
/// What it enforces itself is the store boundary: events are buffered while the
/// stores are still loading, and activation keeps only the two identifiers that
/// actually opened. A completion counts only when its own start was accepted,
/// so a completion for a store this session never opened cannot settle
/// anything.
public struct SyncSessionReducer: Equatable, Sendable {
    private struct StoreEventKey: Hashable {
        let storeIdentifier: String
        let kind: SyncEventKind
    }

    private enum Outcome: Equatable {
        case succeeded
        case failedNetwork
        case failedOther
    }

    private var isActive = false
    private var activeStores: Set<String> = []
    /// Pre-activation events in notification order, one entry per event
    /// identifier and phase, so a replay sees the same starts and completions
    /// the live path would have seen.
    private var buffered: [SyncEvent] = []
    /// Accepted starts that have not been completed yet, keyed by event id.
    private var pendingStarts: [String: SyncEvent] = [:]
    private var outcomes: [StoreEventKey: Outcome] = [:]

    public init() {}

    // MARK: - Input

    public mutating func record(_ event: SyncEvent) {
        guard isActive else {
            buffer(event)
            return
        }
        guard activeStores.contains(event.storeIdentifier) else { return }
        apply(event)
    }

    /// Discards everything buffered for a store this session did not open, then
    /// replays the rest. From here on only the two identifiers are accepted.
    public mutating func activate(storeIdentifiers: Set<String>) {
        guard !isActive else { return }
        isActive = true
        activeStores = storeIdentifiers
        let replay = buffered.filter { storeIdentifiers.contains($0.storeIdentifier) }
        buffered = []
        for event in replay { apply(event) }
    }

    private mutating func buffer(_ event: SyncEvent) {
        if let index = buffered.firstIndex(where: {
            $0.identifier == event.identifier && $0.isComplete == event.isComplete
        }) {
            buffered[index] = event
        } else {
            buffered.append(event)
        }
    }

    private mutating func apply(_ event: SyncEvent) {
        guard event.isComplete else {
            pendingStarts[event.identifier] = event
            return
        }
        // A completion whose start was never accepted belongs to work this
        // session did not begin.
        guard pendingStarts.removeValue(forKey: event.identifier) != nil else { return }

        let key = StoreEventKey(storeIdentifier: event.storeIdentifier, kind: event.kind)
        if event.succeeded {
            outcomes[key] = .succeeded
        } else {
            outcomes[key] = event.isNetworkFailure ? .failedNetwork : .failedOther
        }
    }

    // MARK: - Output

    /// The bootstrap barrier: this store finished a successful first setup and
    /// import in *this* session, so an empty local cache is now evidence that
    /// the account really has no household rather than one still arriving.
    public func hasCompletedInitialImport(storeIdentifier: String) -> Bool {
        [SyncEventKind.setup, .importChanges].allSatisfy {
            outcomes[StoreEventKey(storeIdentifier: storeIdentifier, kind: $0)] == .succeeded
        }
    }

    public func status(account: SyncAccountState, isNetworkReachable: Bool) -> SyncStatus {
        if account == .unavailable { return .needsAttention }
        if outcomes.values.contains(.failedOther) { return .needsAttention }
        if !isNetworkReachable { return .offline }
        // A network failure is not settled state: the container retries it, so
        // the honest label is still "syncing" once the network is back.
        if !isActive || !pendingStarts.isEmpty || outcomes.values.contains(.failedNetwork) {
            return .syncing
        }
        return activeStores.allSatisfy { hasCompletedInitialImport(storeIdentifier: $0) }
            ? .upToDate : .syncing
    }
}
