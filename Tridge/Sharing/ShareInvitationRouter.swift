import CloudKit
import Observation

/// The parts of an invitation the router decides on.
///
/// A protocol rather than `CKShare.Metadata` directly, because that type has no
/// public initializer: the routing rules — container check, pending-only
/// acceptance, reopen paths — would otherwise be unreachable from a test, and
/// they are exactly the rules that must not be got wrong.
protocol ShareInvitationMetadata {
    var invitationContainerIdentifier: String { get }
    var invitationParticipantStatus: CKShare.ParticipantAcceptanceStatus { get }
}

extension CKShare.Metadata: ShareInvitationMetadata {
    var invitationContainerIdentifier: String { containerIdentifier }
    var invitationParticipantStatus: CKShare.ParticipantAcceptanceStatus { participantStatus }
}

/// Routes a tapped invitation into this account's shared store.
///
/// Warm and cold scene delivery both land here, so there is one place that
/// checks the container, waits for the shared store, and decides what a
/// participant status means. Metadata is held **in memory for this live process
/// only**: no invitation URL, zone hash, phase, or auto-selection intent is ever
/// persisted or logged. If the process ends before acceptance, the user reopens
/// the invitation; if it ends after the server accepted, normal CloudKit import
/// still makes the Household discoverable.
@MainActor
@Observable
final class ShareInvitationRouter {
    /// The one router the scene delegates deliver to. Tests construct their own.
    static let shared = ShareInvitationRouter()

    enum Status: Equatable {
        case idle
        /// Metadata is held until this account's shared store is ready.
        case waitingForStore
        case accepting
        /// The server accepted. The Household appears through normal import; it
        /// does not become active (ADR 0013).
        case accepted
        /// Recoverable. Retry is offered while the metadata is still live.
        case failed(HouseholdActionFailure)
        /// `.removed` or `.unknown`: there is nothing to accept, and guessing
        /// would create a local imitation of somebody else's Household.
        case needsReopen
        /// The metadata is not for this app's container.
        case rejected
    }

    private(set) var status: Status = .idle

    private let containerIdentifier: String
    /// In memory, for this process only.
    @ObservationIgnored private var pending: (any ShareInvitationMetadata)?
    /// Set while an account session's shared store is open.
    @ObservationIgnored private var accept: ((any ShareInvitationMetadata) async throws -> Void)?
    /// Bumped every time `pending` is replaced or dropped. An acceptance
    /// carries the value it started under, so completion can tell whether the
    /// invitation it was for is still the one being held — `CKShare.Metadata`
    /// offers no id of its own to compare, and the protocol has value-type
    /// conformers, so object identity would not do.
    @ObservationIgnored private var pendingGeneration: UInt64 = 0
    /// The generation of the acceptance in flight, or nil when none is.
    @ObservationIgnored private var acceptingGeneration: UInt64?

    init(containerIdentifier: String = TridgeCloudKit.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    /// Whether the user can still be offered Retry — true only while the
    /// metadata this process received is still held.
    var canRetry: Bool {
        guard case .failed = status else { return false }
        return pending != nil && acceptingGeneration == nil
    }

    /// The single entry point for both scene routes.
    func receive(_ metadata: any ShareInvitationMetadata) {
        guard metadata.invitationContainerIdentifier == containerIdentifier else {
            // Another app's invitation reached this process; nothing to do, and
            // nothing about it is retained.
            status = .rejected
            return
        }
        switch metadata.invitationParticipantStatus {
        case .pending:
            pending = metadata
            pendingGeneration += 1
            acceptIfPossible()
        case .accepted:
            // Already accepted server-side. Acceptance is not invoked again;
            // normal import brings the Household in.
            pending = nil
            pendingGeneration += 1
            status = .accepted
        default:
            // `.removed`, `.unknown`, and anything added later: reopening the
            // invitation is the only honest path.
            pending = nil
            pendingGeneration += 1
            status = .needsReopen
        }
    }

    /// Called when an account session's shared store is open, and again with
    /// nil when that session ends.
    func bind(accept: ((any ShareInvitationMetadata) async throws -> Void)?) {
        self.accept = accept
        if accept == nil {
            // The session is going away. The metadata stays in memory for this
            // process, so the next session can still accept it.
            if case .accepting = status { status = .waitingForStore }
        } else {
            acceptIfPossible()
        }
    }

    /// Retries a recoverable failure while the metadata is still live.
    func retry() {
        guard canRetry else { return }
        acceptIfPossible()
    }

    /// Clears a settled status once the user has seen it. Pending metadata is
    /// dropped with it, which is the same as never having received it.
    func dismiss() {
        pending = nil
        // Bumped so an acceptance still in flight settles as stale rather than
        // overwriting the idle state the user just asked for.
        pendingGeneration += 1
        status = .idle
    }

    private func acceptIfPossible() {
        guard let metadata = pending, acceptingGeneration == nil else { return }
        guard let accept else {
            status = .waitingForStore
            return
        }

        let generation = pendingGeneration
        acceptingGeneration = generation
        status = .accepting
        Task { [weak self] in
            do {
                try await accept(metadata)
                self?.finish(.accepted, generation: generation, clearingPending: true)
            } catch {
                // The metadata is still held, so Retry is real rather than a
                // button that reopens nothing.
                self?.finish(.failed(HouseholdActionFailure(error, stage: "invitation")),
                             generation: generation, clearingPending: false)
            }
        }
    }

    /// Settles the acceptance that just returned.
    ///
    /// A second invitation opened while the first was in flight has already
    /// replaced `pending`, and it must not be cleared by the first one's
    /// success or described by the first one's failure: that would report
    /// somebody else's fridge as joined, or offer Try Again against an
    /// invitation the error was never about. A stale result is dropped and the
    /// invitation now held starts its own acceptance instead.
    private func finish(_ status: Status, generation: UInt64, clearingPending: Bool) {
        acceptingGeneration = nil
        guard generation == pendingGeneration else {
            acceptIfPossible()
            return
        }
        if clearingPending { pending = nil }
        self.status = status
    }
}
