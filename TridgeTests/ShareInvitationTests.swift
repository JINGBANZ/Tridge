import CloudKit
import XCTest
@testable import Tridge

/// Invitation routing: one path for warm and cold delivery, acceptance only for
/// pending metadata, nothing about an invitation persisted, and a received
/// Household that never steals the active selection.
@MainActor
final class ShareInvitationTests: XCTestCase {
    /// Stands in for `CKShare.Metadata`, which has no public initializer.
    private struct Invitation: ShareInvitationMetadata {
        var invitationContainerIdentifier = TridgeCloudKit.containerIdentifier
        var invitationParticipantStatus: CKShare.ParticipantAcceptanceStatus = .pending
    }

    /// Records what the router asked CloudKit to do.
    private final class Acceptor: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _failure: Error?
        private var _gate: TestGate?

        var count: Int { lock.withLock { _count } }

        var failure: Error? {
            get { lock.withLock { _failure } }
            set { lock.withLock { _failure = newValue } }
        }

        var gate: TestGate? {
            get { lock.withLock { _gate } }
            set { lock.withLock { _gate = newValue } }
        }

        func accept(_ metadata: any ShareInvitationMetadata) async throws {
            if let gate { await gate.wait() }
            let failure: Error? = lock.withLock {
                _count += 1
                return _failure
            }
            if let failure { throw failure }
        }
    }

    private var acceptor: Acceptor!
    private var router: ShareInvitationRouter!

    override func setUp() {
        super.setUp()
        acceptor = Acceptor()
        router = ShareInvitationRouter()
    }

    private func bind() {
        let acceptor = self.acceptor!
        router.bind { try await acceptor.accept($0) }
    }

    // MARK: - Container

    func testAnInvitationForAnotherContainerIsRejectedAndNotRetained() {
        bind()
        router.receive(Invitation(invitationContainerIdentifier: "iCloud.com.example.other"))

        XCTAssertEqual(router.status, .rejected)
        XCTAssertFalse(router.canRetry)
        XCTAssertEqual(acceptor.count, 0)
    }

    // MARK: - Participant status

    func testOnlyPendingMetadataInvokesAcceptance() async {
        bind()

        router.receive(Invitation(invitationParticipantStatus: .accepted))
        XCTAssertEqual(router.status, .accepted)
        XCTAssertEqual(acceptor.count, 0, "an already accepted invitation is not accepted again")

        router.receive(Invitation(invitationParticipantStatus: .removed))
        XCTAssertEqual(router.status, .needsReopen)
        router.receive(Invitation(invitationParticipantStatus: .unknown))
        XCTAssertEqual(router.status, .needsReopen,
                       "an unknown status is never guessed at")
        XCTAssertEqual(acceptor.count, 0)

        router.receive(Invitation())
        await waitUntil("the pending invitation is accepted") { self.router.status == .accepted }
        XCTAssertEqual(acceptor.count, 1)
    }

    // MARK: - Waiting for the store

    func testMetadataIsHeldUntilTheSharedStoreIsReady() async {
        // Cold launch: the invitation arrives before any account session.
        router.receive(Invitation())
        XCTAssertEqual(router.status, .waitingForStore)
        XCTAssertEqual(acceptor.count, 0)

        bind()
        await waitUntil("acceptance runs once the store is ready") {
            self.router.status == .accepted
        }
        XCTAssertEqual(acceptor.count, 1)
    }

    func testASessionEndingWhileAcceptingReturnsToWaiting() async {
        let gate = TestGate()
        acceptor.gate = gate
        bind()
        router.receive(Invitation())
        await waitUntil("acceptance starts") { self.router.status == .accepting }

        router.bind(accept: nil)
        XCTAssertEqual(router.status, .waitingForStore,
                       "the metadata survives the session, the acceptance does not")
        await gate.open()
    }

    // MARK: - Retry

    func testARecoverableFailureOffersRetryWhileTheMetadataIsLive() async {
        acceptor.failure = CKError(.networkUnavailable)
        bind()
        router.receive(Invitation())
        await waitUntil("the attempt fails") {
            if case .failed = self.router.status { return true }
            return false
        }
        XCTAssertTrue(router.canRetry)

        acceptor.failure = nil
        router.retry()
        await waitUntil("the retry succeeds") { self.router.status == .accepted }
        XCTAssertEqual(acceptor.count, 2)
        XCTAssertFalse(router.canRetry, "there is nothing left to retry")
    }

    func testAPlatformLimitFailureIsRetryableAndChangesNothing() async {
        acceptor.failure = CKError(.limitExceeded)
        bind()
        router.receive(Invitation())
        await waitUntil("the attempt fails") {
            if case .failed = self.router.status { return true }
            return false
        }

        guard case .failed(let failure) = router.status else {
            return XCTFail("expected a recorded failure")
        }
        XCTAssertEqual(failure.reason, .limitReached)
        XCTAssertTrue(router.canRetry)
    }

    // MARK: - Nothing is persisted

    func testNoInvitationStateReachesUserDefaults() async {
        let suiteName = "ShareInvitationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        bind()
        router.receive(Invitation())
        await waitUntil("the invitation is accepted") { self.router.status == .accepted }

        // The suite's own domain, not `dictionaryRepresentation()`, which
        // reports every inherited global as well.
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty,
                      "invitation URLs, zones, phase, and selection intent are memory-only")
    }

    func testDismissingDropsTheHeldMetadata() async {
        acceptor.failure = CKError(.networkUnavailable)
        bind()
        router.receive(Invitation())
        await waitUntil("the attempt fails") { self.router.canRetry }

        router.dismiss()

        XCTAssertEqual(router.status, .idle)
        XCTAssertFalse(router.canRetry)
        router.retry()
        XCTAssertEqual(acceptor.count, 1, "there is nothing left to retry with")
    }

    // MARK: - Wording

    func testInvitationWordingNeverNamesAShareOrAParticipant() {
        let messages = [
            InvitationStatusText.message(for: .waitingForStore),
            InvitationStatusText.message(for: .accepting),
            InvitationStatusText.message(for: .accepted),
            InvitationStatusText.message(for: .needsReopen),
            InvitationStatusText.message(for: .rejected),
        ]
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.lowercased().contains("http"))
            XCTAssertFalse(message.lowercased().contains("zone"))
            XCTAssertFalse(message.lowercased().contains("ckshare"))
        }
        XCTAssertTrue(InvitationStatusText.isSettled(.needsReopen))
        XCTAssertFalse(InvitationStatusText.isSettled(.accepting))
    }
}

/// The invitation restrictions every Tridge share carries.
final class HouseholdShareItemTests: XCTestCase {
    func testSharesArePrivateReadWriteOnly() {
        let options = HouseholdShareItem.allowedSharingOptions

        XCTAssertEqual(options.allowedParticipantAccessOptions, .specifiedRecipientsOnly,
                       "public links are never offered")
        XCTAssertEqual(options.allowedParticipantPermissionOptions, .readWrite,
                       "there is no read-only product role")
    }
}
