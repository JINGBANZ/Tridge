import CloudKit
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

    /// Polls for something a test expects *never* to happen, so an interleaving
    /// being ruled out can be asserted the same way one being waited for is.
    @MainActor
    func neverHappens(_ description: String, _ condition: @MainActor () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<40 {
            if condition() {
                XCTFail(description, file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
    /// What each command answers with, in the order the commands arrive; the
    /// last one answers every command after it.
    private let commandProjections: [HouseholdProjection]
    private var _readGate: (@Sendable () async -> Void)?
    private var _commandGate: (@Sendable () async -> Void)?
    private var _readCount = 0
    private var _commandCount = 0

    init(read: HouseholdProjection, commands: [HouseholdProjection]) {
        self.readProjection = read
        self.commandProjections = commands
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

    func updateItem(_ command: UpdateItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    func consumeItem(_ command: ConsumeItemCommand,
                     today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    func deleteItem(_ command: DeleteItemCommand,
                    today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    func clearActiveHousehold(_ command: ClearHouseholdCommand,
                              today: InventoryDay) async throws -> HouseholdProjection {
        await respond()
    }

    func renameOwnedHousehold(_ command: RenameHouseholdCommand) async throws -> HouseholdSnapshot {
        HouseholdSnapshot(id: command.householdID, name: command.name, ownership: .owned,
                          createdAt: Date(), isShared: false)
    }

    private func respond() async -> HouseholdProjection {
        let call: Int = lock.withLock {
            _commandCount += 1
            return _commandCount
        }
        if let commandGate { await commandGate() }
        return commandProjections[min(call, commandProjections.count) - 1]
    }
}

/// A notification centre that records instead of scheduling, so a suite never
/// touches the test host's real alerts or badge.
final class FakeNotificationCenter: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [String: PreparedReminder] = [:]
    private var _delivered: [String] = []
    private var _badge = 0
    private var _authorizationRequests = 0

    /// Alerts already sitting in Notification Center, which a scope retirement
    /// has to remove as well as the pending requests.
    var delivered: [String] {
        get { lock.withLock { _delivered } }
        set { lock.withLock { _delivered = newValue } }
    }

    var pending: [PreparedReminder] {
        lock.withLock { scheduled.values.sorted { $0.identifier < $1.identifier } }
    }

    var badge: Int { lock.withLock { _badge } }

    var authorizationRequests: Int { lock.withLock { _authorizationRequests } }

    func isAuthorizationUndetermined() async -> Bool { true }

    func requestAuthorization() async {
        lock.withLock { _authorizationRequests += 1 }
    }

    func pendingReminders() async -> [ScheduledReminder] {
        pending.map {
            ScheduledReminder(identifier: $0.identifier, fireDay: $0.fireDay, hour: $0.hour)
        }
    }

    func deliveredIdentifiers() async -> [String] { delivered }

    func schedule(_ reminders: [PreparedReminder], calendar: Calendar) {
        lock.withLock {
            // Adding under an existing identifier replaces it, exactly as
            // `UNUserNotificationCenter` does — which is what makes a reminder-
            // hour change a reschedule rather than a duplicate.
            for reminder in reminders { scheduled[reminder.identifier] = reminder }
        }
    }

    func removePending(identifiers: [String]) {
        lock.withLock { for identifier in identifiers { scheduled[identifier] = nil } }
    }

    func removeDelivered(identifiers: [String]) {
        lock.withLock { _delivered.removeAll { identifiers.contains($0) } }
    }

    func setBadge(_ count: Int) {
        lock.withLock { _badge = count }
    }
}

/// A sharing service with no CloudKit behind it, so the owner flows — create,
/// refresh, title write, accept — can be driven before any live container
/// exists.
@MainActor
final class FakeHouseholdSharing: HouseholdSharing {
    /// Households that already have a share.
    var sharedHouseholds: Set<UUID> = []
    /// The title last written for each Household's share.
    private(set) var titles: [UUID: String] = [:]
    /// Thrown by the next `prepareShare`, then cleared.
    var prepareFailure: Error?
    var acceptFailure: Error?
    private(set) var prepareCount = 0
    private(set) var acceptCount = 0

    func sharedHouseholdIDs(among householdIDs: [UUID]) async -> Set<UUID> {
        sharedHouseholds.intersection(householdIDs)
    }

    func currentShare(for householdID: UUID) async throws -> CKShare? {
        sharedHouseholds.contains(householdID) ? Self.makeShare() : nil
    }

    func prepareShare(for householdID: UUID, title: String) async throws -> HouseholdShareItem {
        prepareCount += 1
        if let prepareFailure {
            self.prepareFailure = nil
            throw prepareFailure
        }
        sharedHouseholds.insert(householdID)
        titles[householdID] = title
        return HouseholdShareItem(share: Self.makeShare(),
                                  container: CKContainer(identifier: TridgeCloudKit.containerIdentifier),
                                  title: title)
    }

    func accept(_ metadata: any ShareInvitationMetadata) async throws {
        acceptCount += 1
        if let acceptFailure {
            self.acceptFailure = nil
            throw acceptFailure
        }
    }

    /// Zones whose purge should report the server zone already gone.
    var missingZones: Set<UUID> = []
    var purgeFailure: Error?
    private(set) var purgedHouseholds: [UUID] = []

    /// What `capturedRecords` reports for a Household — empty means it was
    /// never mirrored, which completes a private deletion on the local save.
    var recordsByHousehold: [UUID: [CapturedCloudKitRecord]] = [:]
    /// Records the private database still reports as present.
    var recordsStillPresent: Set<String> = []
    var confirmFailure: Error?
    private(set) var confirmCount = 0

    func capturedRecords(of householdID: UUID) async throws -> [CapturedCloudKitRecord] {
        recordsByHousehold[householdID] ?? []
    }

    func confirmRecordsAbsent(_ records: [CapturedCloudKitRecord]) async throws -> Bool {
        confirmCount += 1
        if let confirmFailure {
            self.confirmFailure = nil
            throw confirmFailure
        }
        return records.allSatisfy { !recordsStillPresent.contains($0.recordName) }
    }

    func purgeZone(of householdID: UUID,
                   in scope: HouseholdDatabaseScope) async throws -> PurgeOutcome {
        if let purgeFailure {
            self.purgeFailure = nil
            throw purgeFailure
        }
        purgedHouseholds.append(householdID)
        guard !missingZones.contains(householdID) else { return .zoneAlreadyMissing }
        sharedHouseholds.remove(householdID)
        return .purged
    }

    /// A share object constructed locally. It is never saved, so no container
    /// is contacted.
    private static func makeShare() -> CKShare {
        CKShare(recordZoneID: CKRecordZone.ID(zoneName: "tridge.test",
                                              ownerName: CKCurrentUserDefaultName))
    }
}
