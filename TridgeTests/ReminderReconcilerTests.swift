import Foundation
import XCTest
@testable import Tridge

/// The Apple-platform side of expiry reminders: the diff `NotificationPlan`
/// produces, applied to a notification centre.
///
/// Reminders cover the Active Household only, so the interesting cases are the
/// transitions — an hour change, an item leaving, a Household or account being
/// retired — where the wrong scope would either strand an alert or remove one
/// that still belongs to somebody.
@MainActor
final class ReminderReconcilerTests: XCTestCase {
    private var center: FakeNotificationCenter!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var reconciler: ReminderReconciler!

    /// Fixed so a fire date never depends on when the suite runs. 10:00 local,
    /// which is after the default 9 AM reminder hour — so a reminder due
    /// *today* at 9 is already past and is deliberately not requested.
    private static let now = Date(timeIntervalSince1970: 1_787_133_600)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let scope = AccountScopeHash(digest: String(repeating: "e", count: 64))!
    private static let otherScope = AccountScopeHash(digest: String(repeating: "f", count: 64))!
    private let householdID = UUID()
    private let otherHouseholdID = UUID()

    private var today: InventoryDay {
        InventoryDay.today(in: Self.calendar, now: Self.now)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        center = FakeNotificationCenter()
        suiteName = "ReminderReconcilerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        reconciler = makeReconciler()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func makeReconciler() -> ReminderReconciler {
        // Copied into locals first: the closures are `@Sendable`, and a static
        // on this main-actor suite cannot be read from inside one.
        let calendar = Self.calendar
        let now = Self.now
        return ReminderReconciler(center: center, defaults: defaults,
                                  calendar: { calendar }, now: { now })
    }

    private func item(_ name: String, id: UUID = UUID(),
                      expiresInDays: Int) -> InventoryItemSnapshot {
        InventoryItemSnapshot(id: id, memberIDs: [id], name: name,
                              normalizedName: NameKey.normalize(name), quantity: 1,
                              artKey: ItemID.milk.rawValue, storage: .fridge,
                              purchaseDay: today,
                              expiryDay: today.adding(days: expiresInDays)!,
                              expirySource: .llmEstimate)
    }

    private func identifier(_ itemID: UUID, _ kind: ReminderKind,
                            scope: AccountScopeHash? = nil,
                            householdID: UUID? = nil) -> String {
        ReminderIdentifier(accountScope: (scope ?? Self.scope).value,
                           householdID: householdID ?? self.householdID,
                           itemID: itemID, kind: kind).rawValue
    }

    // MARK: - Desired state

    func testEachActiveItemGetsAWarningAndAnExpiryDayReminder() async throws {
        let milk = item("Milk", expiresInDays: 6)
        await reconciler.reconcile(items: [milk], accountScope: Self.scope,
                                   householdID: householdID)

        XCTAssertEqual(center.pending.map(\.identifier).sorted(),
                       [identifier(milk.id, .day), identifier(milk.id, .pre)].sorted())
        let warning = try XCTUnwrap(center.pending.first {
            $0.identifier == identifier(milk.id, .pre)
        })
        XCTAssertEqual(warning.fireDay, today.adding(days: 4),
                       "two days before expiry")
        XCTAssertEqual(warning.hour, ReminderReconciler.defaultHour)
        XCTAssertTrue(warning.body.contains("Milk"))
    }

    func testAnItemLeavingRetiresOnlyItsOwnRequests() async throws {
        let milk = item("Milk", expiresInDays: 6)
        let eggs = item("Eggs", expiresInDays: 9)
        await reconciler.reconcile(items: [milk, eggs], accountScope: Self.scope,
                                   householdID: householdID)
        XCTAssertEqual(center.pending.count, 4)

        await reconciler.reconcile(items: [eggs], accountScope: Self.scope,
                                   householdID: householdID)

        XCTAssertEqual(center.pending.map(\.identifier).sorted(),
                       [identifier(eggs.id, .day), identifier(eggs.id, .pre)].sorted())
    }

    /// A newly imported lower-id merge member changes the logical id, and the
    /// desired-state diff has to retire the identifier the old one owned.
    func testANewLogicalIdentityRetiresTheObsoleteIdentifier() async throws {
        let before = item("Milk", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                          expiresInDays: 6)
        await reconciler.reconcile(items: [before], accountScope: Self.scope,
                                   householdID: householdID)

        let after = item("Milk", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                         expiresInDays: 6)
        await reconciler.reconcile(items: [after], accountScope: Self.scope,
                                   householdID: householdID)

        XCTAssertEqual(center.pending.map(\.identifier).sorted(),
                       [identifier(after.id, .day), identifier(after.id, .pre)].sorted())
    }

    // MARK: - Reminder hour

    func testChangingTheReminderHourReschedulesRatherThanDuplicates() async throws {
        let milk = item("Milk", expiresInDays: 6)
        await reconciler.reconcile(items: [milk], accountScope: Self.scope,
                                   householdID: householdID)
        XCTAssertEqual(Set(center.pending.map(\.hour)), [ReminderReconciler.defaultHour])

        defaults.set(18, forKey: ReminderReconciler.reminderHourKey)
        await reconciler.reconcile(items: [milk], accountScope: Self.scope,
                                   householdID: householdID)

        XCTAssertEqual(center.pending.count, 2, "replaced in place, not duplicated")
        XCTAssertEqual(Set(center.pending.map(\.hour)), [18])
    }

    // MARK: - Badge

    func testTheBadgeIsTheActiveHouseholdsExpiredCount() async throws {
        await reconciler.reconcile(
            items: [item("Milk", expiresInDays: -1), item("Salmon", expiresInDays: -3),
                    item("Eggs", expiresInDays: 6)],
            accountScope: Self.scope, householdID: householdID)

        XCTAssertEqual(center.badge, 2)
    }

    // MARK: - Permission

    func testReconciliationNeverPromptsForPermission() async throws {
        await reconciler.reconcile(items: [item("Milk", expiresInDays: 6)],
                                   accountScope: Self.scope, householdID: householdID)

        XCTAssertEqual(center.authorizationRequests, 0,
                       "a remote import must not raise a permission prompt")

        await reconciler.requestPermissionIfNeeded()
        XCTAssertEqual(center.authorizationRequests, 1, "an explicit add still asks once")
    }

    // MARK: - Scope retirement

    func testRetiringAHouseholdRemovesItsPendingAndDeliveredAlertsOnly() async throws {
        let mine = item("Milk", expiresInDays: 6)
        let theirs = item("Butter", expiresInDays: 6)
        await reconciler.reconcile(items: [mine], accountScope: Self.scope,
                                   householdID: householdID)
        await reconciler.reconcile(items: [theirs], accountScope: Self.scope,
                                   householdID: otherHouseholdID)
        center.delivered = [
            identifier(mine.id, .day),
            identifier(theirs.id, .day, householdID: otherHouseholdID),
            "some.other.app.notification",
        ]

        await reconciler.retire(scope: .household(accountScope: Self.scope.value,
                                                  householdID: householdID))

        XCTAssertEqual(center.pending.map(\.identifier).sorted(),
                       [identifier(theirs.id, .day, householdID: otherHouseholdID),
                        identifier(theirs.id, .pre, householdID: otherHouseholdID)].sorted(),
                       "the other Household keeps its schedule")
        XCTAssertEqual(center.delivered.sorted(),
                       [identifier(theirs.id, .day, householdID: otherHouseholdID),
                        "some.other.app.notification"].sorted(),
                       "only this scope's delivered alerts are cleared")
    }

    func testRetiringAnAccountRemovesEveryHouseholdUnderIt() async throws {
        let mine = item("Milk", expiresInDays: 6)
        let other = item("Butter", expiresInDays: 6)
        await reconciler.reconcile(items: [mine], accountScope: Self.scope,
                                   householdID: householdID)
        await reconciler.reconcile(items: [other], accountScope: Self.otherScope,
                                   householdID: otherHouseholdID)

        await reconciler.retire(scope: .account(Self.scope.value))

        XCTAssertEqual(
            center.pending.map(\.identifier).sorted(),
            [identifier(other.id, .day, scope: Self.otherScope, householdID: otherHouseholdID),
             identifier(other.id, .pre, scope: Self.otherScope,
                        householdID: otherHouseholdID)].sorted(),
            "the other account is untouched")
    }
}
