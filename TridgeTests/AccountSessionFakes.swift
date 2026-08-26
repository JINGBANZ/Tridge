import CoreData
import Foundation
import XCTest
@testable import Tridge

/// Test doubles shared by the account-session and upgrade suites, so both drive
/// the coordinator through the same seams the app uses.
final class FakeAccountIdentity: AccountIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<AccountScopeHash, Error>

    init(result: Result<AccountScopeHash, Error>) {
        self._result = result
    }

    var result: Result<AccountScopeHash, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    func validateCurrentAccountScope() async throws -> AccountScopeHash {
        try result.get()
    }
}

/// Opens real local-only stacks so store identifiers, routing, and teardown are
/// the production ones, while letting a test hold the load open or fail it.
final class StackLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let baseDirectory: URL
    private var _controllers: [PersistenceController] = []

    private var _gate: (@Sendable () async -> Void)?
    private var _failure: Error?

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Loads run off the main actor while the test mutates these from it, so
    /// both cross the same lock as `_controllers`.
    var gate: (@Sendable () async -> Void)? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var controllers: [PersistenceController] { lock.withLock { _controllers } }

    var closure: @Sendable (AccountScopeHash) async throws -> PersistenceController {
        { [self] scope in try await load(scope) }
    }

    func tearDownAll() {
        for controller in controllers { controller.tearDown() }
    }

    private func load(_ scope: AccountScopeHash) async throws -> PersistenceController {
        if let gate { await gate() }
        if let failure { throw failure }
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
        lock.withLock { _controllers.append(controller) }
        return controller
    }
}

extension XCTestCase {
    /// Polls until `condition` holds, for the coordinator work that settles
    /// after the call that started it has already returned.
    @MainActor
    func waitUntil(_ description: String, _ condition: @MainActor () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}

/// An archive whose contents a test controls, so the upgrade can be driven
/// without a SwiftData store on disk.
final class FakeLegacyArchive: LegacyInventoryArchiveReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [LegacyInventoryRow]
    private var _exists: Bool
    private var _readFailure: Error?
    private var _readCount = 0

    init(rows: [LegacyInventoryRow], exists: Bool = true) {
        self._rows = rows
        self._exists = exists
    }

    /// The active rows the reader would return.
    var rows: [LegacyInventoryRow] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }

    var exists: Bool {
        get { lock.withLock { _exists } }
        set { lock.withLock { _exists = newValue } }
    }

    var readFailure: Error? {
        get { lock.withLock { _readFailure } }
        set { lock.withLock { _readFailure = newValue } }
    }

    var readCount: Int { lock.withLock { _readCount } }

    func readActiveRows() throws -> [LegacyInventoryRow] {
        try lock.withLock {
            _readCount += 1
            if let _readFailure { throw _readFailure }
            return _rows
        }
    }
}

final class RecordingLegacyEffects: LegacyEffectsCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var clearCount: Int { lock.withLock { count } }

    func clearScheduledAndDeliveredNotifications() {
        lock.withLock { count += 1 }
    }
}

/// Denies exactly what a revoked share denies, without a live `CKShare`. The
/// answers are fixed at construction, so the writer queue and the test thread
/// never race for them.
final class FakeStoreCapabilities: StoreCapabilityChecking, @unchecked Sendable {
    private let modify: Bool
    private let update: Bool

    init(canModify: Bool = true, canUpdate: Bool = true) {
        self.modify = canModify
        self.update = canUpdate
    }

    func canModifyManagedObjects(in store: NSPersistentStore) -> Bool { modify }

    func canUpdateRecord(forManagedObjectWith objectID: NSManagedObjectID) -> Bool { update }
}

/// A one-shot handshake: callers wait here until the test opens the gate.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A repository whose reads and commands can each be held open, so a test can
/// land a command's newer projection while an older read is still suspended, or
/// re-point the session while a command is still in flight.
final class GatedInventoryRepository: InventoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let readProjection: HouseholdProjection
    private let commandProjection: HouseholdProjection
    private var _readGate: (@Sendable () async -> Void)?
    private var _commandGate: (@Sendable () async -> Void)?
    private var _readCount = 0
    private var _commandCount = 0

    init(read: HouseholdProjection, command: HouseholdProjection) {
        self.readProjection = read
        self.commandProjection = command
    }

    /// Reads run off the main actor while the test sets this from it, so both
    /// cross the same lock as `_readCount`.
    var readGate: (@Sendable () async -> Void)? {
        get { lock.withLock { _readGate } }
        set { lock.withLock { _readGate = newValue } }
    }

    /// Held open the same way as `readGate`, so a test can re-point the
    /// session while a command is still writing.
    var commandGate: (@Sendable () async -> Void)? {
        get { lock.withLock { _commandGate } }
        set { lock.withLock { _commandGate = newValue } }
    }

    var readCount: Int { lock.withLock { _readCount } }

    var commandCount: Int { lock.withLock { _commandCount } }

    func projection(of householdID: UUID,
                    today: InventoryDay) async throws -> HouseholdProjection {
        lock.withLock { _readCount += 1 }
        if let readGate { await readGate() }
        return readProjection
    }

    func addManualItem(_ command: AddManualItemCommand,
                       today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    func addReviewedRows(_ command: AddReviewedRowsCommand,
                         today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    private func respond() async -> HouseholdProjection {
        lock.withLock { _commandCount += 1 }
        if let commandGate { await commandGate() }
        return commandProjection
    }
}
