import Foundation

/// One CloudKit record Tridge captured before deleting the object it maps to.
///
/// These opaque components exist only so a resumed deletion can ask the private
/// database whether that exact record is really gone. They are never logged, and
/// they are cleared with the transition that captured them.
struct CapturedCloudKitRecord: Equatable, Codable {
    let recordName: String
    let zoneName: String
    let zoneOwnerName: String
}

/// A Household lifecycle change that spans more than one irreversible step, so
/// it has to survive termination.
///
/// The phases are the contract's, and each one names exactly what has already
/// happened — never what is intended. A resume reads the phase and continues;
/// it never re-does a step that a later phase proves was completed.
struct HouseholdLifecycleTransition: Equatable, Codable {
    enum Kind: String, Codable {
        /// The owner keeps the inventory this installation can see, then
        /// revokes the share.
        case stopSharing
        /// The owner deletes an unshared Household, with CloudKit absence
        /// verified before it is called complete.
        case deletePrivate
        /// The owner deletes a shared Household for everyone. No copy is made.
        case deleteShared
    }

    enum Phase: String, Codable {
        /// The copy has been started but not saved.
        case copying
        /// The private copy is saved and refetchable. The source is still there.
        case copySaved
        /// The copy is verified; the source zone may now be purged.
        case purgePending
        /// Record ids captured; the local graph may or may not be deleted yet.
        case privateDeletePrepared
        /// The local graph is gone; CloudKit absence has not been confirmed.
        case privateDeleteAwaitingCloud
    }

    let kind: Kind
    var phase: Phase
    let sourceHouseholdID: UUID
    /// Preallocated before the copy starts, so a retry finds the copy it
    /// already made instead of creating a second one.
    let destinationHouseholdID: UUID?
    /// Opaque record components for a verified private deletion.
    var capturedRecords: [CapturedCloudKitRecord]

    init(kind: Kind, phase: Phase, sourceHouseholdID: UUID,
         destinationHouseholdID: UUID? = nil,
         capturedRecords: [CapturedCloudKitRecord] = []) {
        self.kind = kind
        self.phase = phase
        self.sourceHouseholdID = sourceHouseholdID
        self.destinationHouseholdID = destinationHouseholdID
        self.capturedRecords = capturedRecords
    }

    /// Households that must stay out of normal interaction until this finishes.
    var suppressedHouseholdIDs: Set<UUID> {
        switch kind {
        case .stopSharing:
            // The destination is suppressed only while it is half-built; once
            // the copy is verified it is the Household the user should get.
            phase == .copying
                ? Set([sourceHouseholdID] + (destinationHouseholdID.map { [$0] } ?? []))
                : [sourceHouseholdID]
        case .deletePrivate, .deleteShared:
            [sourceHouseholdID]
        }
    }
}

/// Where a lifecycle transition is kept between launches.
///
/// Account-scoped and local: this is a record of what this installation was
/// part-way through, never shared data. Only one transition can be pending at a
/// time, which is the same rule that stops two destructive actions from running
/// at once.
struct LifecycleTransitionStore {
    private static let key = "householdLifecycleTransition"

    private let defaults: UserDefaults
    private let accountScope: AccountScopeHash

    init(accountScope: AccountScopeHash, defaults: UserDefaults = .standard) {
        self.accountScope = accountScope
        self.defaults = defaults
    }

    func current() -> HouseholdLifecycleTransition? {
        guard let data = defaults.data(forKey: accountScope.defaultsKey(Self.key)) else {
            return nil
        }
        return try? JSONDecoder().decode(HouseholdLifecycleTransition.self, from: data)
    }

    func save(_ transition: HouseholdLifecycleTransition) {
        guard let data = try? JSONEncoder().encode(transition) else { return }
        defaults.set(data, forKey: accountScope.defaultsKey(Self.key))
    }

    /// Cleared only once the whole transition is finished, so an interruption
    /// resumes rather than being forgotten.
    func clear() {
        defaults.removeObject(forKey: accountScope.defaultsKey(Self.key))
    }
}
