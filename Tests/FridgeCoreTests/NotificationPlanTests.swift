import XCTest
@testable import FridgeCore

final class NotificationPlanTests: XCTestCase {
    private let scope = "9f2c" // the nonlogged account hash
    private let household = UUID()
    private let today = InventoryDay(year: 2026, month: 8, day: 18)!

    private func item(_ id: UUID = UUID(), expiresInDays: Int) -> InventoryItemSnapshot {
        InventoryItemSnapshot(id: id, memberIDs: [id], name: "Milk", normalizedName: "milk",
                              quantity: 1, artKey: ItemID.milk.rawValue, storage: .fridge,
                              purchaseDay: today, expiryDay: today.adding(days: expiresInDays)!,
                              expirySource: .llmEstimate)
    }

    private func desired(_ items: [InventoryItemSnapshot], hour: Int = 9,
                         currentHour: Int = 8) -> [ReminderRequest] {
        NotificationPlan.desiredRequests(items: items, accountScope: scope,
                                         householdID: household, hour: hour,
                                         today: today, currentHour: currentHour)
    }

    func testIdentifiersAreScopedByAccountHouseholdItemAndKind() {
        let item = UUID()
        let identifier = ReminderIdentifier(accountScope: scope, householdID: household,
                                            itemID: item, kind: .pre)
        XCTAssertEqual(identifier.rawValue,
                       "account.\(scope).household.\(household.uuidString).item.\(item.uuidString).pre")
        XCTAssertEqual(ReminderIdentifier(parsing: identifier.rawValue), identifier)
    }

    func testMalformedIdentifiersDoNotParse() {
        XCTAssertNil(ReminderIdentifier(parsing: "milk-pre"))
        XCTAssertNil(ReminderIdentifier(parsing: "account.\(scope).household.nope.item.\(UUID().uuidString).pre"))
        XCTAssertNil(ReminderIdentifier(parsing: "account.\(scope).household.\(household.uuidString).item.\(UUID().uuidString).soon"))
        XCTAssertNil(ReminderIdentifier(parsing: "fridge.\(scope).household.\(household.uuidString).item.\(UUID().uuidString).pre"))
    }

    func testAnAccountScopeContainingTheSeparatorStillRoundTrips() {
        // An identifier that cannot be parsed back would strand its pending and
        // delivered alerts in Notification Center forever.
        let awkward = ReminderIdentifier(accountScope: "9f.2c", householdID: household,
                                         itemID: UUID(), kind: .day)
        XCTAssertEqual(ReminderIdentifier(parsing: awkward.rawValue), awkward)
        XCTAssertEqual(NotificationPlan.identifiers(in: [awkward.rawValue],
                                                    scope: .account("9f.2c")),
                       [awkward.rawValue])
        XCTAssertTrue(NotificationPlan.identifiers(in: [awkward.rawValue],
                                                   scope: .account("9f")).isEmpty)
    }

    func testEachActiveItemWantsATwoDayWarningAndAnExpiryDayReminder() {
        let milk = item(expiresInDays: 5)
        let requests = desired([milk])

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.identifier.kind), [.day, .pre])
        let pre = requests.first { $0.identifier.kind == .pre }
        XCTAssertEqual(pre?.fireDay, today.adding(days: 3))
        XCTAssertEqual(pre?.hour, 9)
        XCTAssertEqual(requests.first { $0.identifier.kind == .day }?.fireDay,
                       today.adding(days: 5))
    }

    func testRemindersInThePastAreNotRequested() {
        // Expiry was yesterday, and today's 9 AM warning already passed.
        XCTAssertTrue(desired([item(expiresInDays: -1)]).isEmpty)
        XCTAssertEqual(desired([item(expiresInDays: 2)], hour: 9, currentHour: 10).count, 1,
                       "only the expiry-day reminder is still ahead")
        XCTAssertEqual(desired([item(expiresInDays: 2)], hour: 9, currentHour: 8).count, 2)
    }

    func testDiffAddsWhatIsMissingAndRemovesWhatIsObsolete() {
        let kept = item(expiresInDays: 5)
        let requests = desired([kept])
        let stale = ReminderIdentifier(accountScope: scope, householdID: household,
                                       itemID: UUID(), kind: .day)

        let diff = NotificationPlan.diff(
            desired: requests,
            pending: [scheduled(requests[0]),
                      ScheduledReminder(identifier: stale.rawValue, fireDay: today, hour: 9)],
            scope: .household(accountScope: scope, householdID: household))

        XCTAssertEqual(diff.add, [requests[1]])
        XCTAssertTrue(diff.update.isEmpty)
        XCTAssertEqual(diff.remove, [stale.rawValue])
    }

    func testChangingTheReminderHourReplacesOtherwiseIdenticalRequests() {
        let milk = item(expiresInDays: 5)
        let atNine = desired([milk], hour: 9)
        let atSeven = desired([milk], hour: 7)

        let diff = NotificationPlan.diff(desired: atSeven, pending: atNine.map(scheduled),
                                         scope: .household(accountScope: scope,
                                                           householdID: household))
        XCTAssertTrue(diff.add.isEmpty)
        XCTAssertTrue(diff.remove.isEmpty)
        XCTAssertEqual(Set(diff.update), Set(atSeven))
        XCTAssertEqual(Set(diff.update.map(\.hour)), [7])
    }

    func testANewLowerIdMergeMemberRetiresTheObsoleteIdentifier() {
        // Reconciliation changed the logical id; the old requests must go.
        let previous = desired([item(expiresInDays: 4)])
        let current = desired([item(expiresInDays: 4)])
        let diff = NotificationPlan.diff(desired: current, pending: previous.map(scheduled),
                                         scope: .household(accountScope: scope,
                                                           householdID: household))
        XCTAssertEqual(Set(diff.add), Set(current))
        XCTAssertEqual(Set(diff.remove), Set(previous.map(\.identifier.rawValue)))
    }

    func testDiffNeverTouchesAnotherHouseholdOrAccount() {
        let mine = desired([item(expiresInDays: 5)])
        let otherHousehold = ReminderIdentifier(accountScope: scope, householdID: UUID(),
                                                itemID: UUID(), kind: .day)
        let otherAccount = ReminderIdentifier(accountScope: "beef", householdID: household,
                                              itemID: UUID(), kind: .day)
        let foreign = "some.other.app.reminder"

        let diff = NotificationPlan.diff(
            desired: mine,
            pending: [ScheduledReminder(identifier: otherHousehold.rawValue, fireDay: today, hour: 9),
                      ScheduledReminder(identifier: otherAccount.rawValue, fireDay: today, hour: 9),
                      ScheduledReminder(identifier: foreign, fireDay: today, hour: 9)],
            scope: .household(accountScope: scope, householdID: household))

        XCTAssertEqual(Set(diff.add), Set(mine))
        XCTAssertTrue(diff.remove.isEmpty)
    }

    func testObsoleteScopeSelectionIsStrictRatherThanSubstringMatching() {
        let mine = ReminderIdentifier(accountScope: scope, householdID: household,
                                      itemID: UUID(), kind: .pre)
        let sameAccountOtherHousehold = ReminderIdentifier(accountScope: scope,
                                                           householdID: UUID(),
                                                           itemID: UUID(), kind: .day)
        // A hash that merely starts with the same characters is a different account.
        let lookalikeAccount = ReminderIdentifier(accountScope: scope + "ff",
                                                  householdID: household,
                                                  itemID: UUID(), kind: .day)
        let all = [mine.rawValue, sameAccountOtherHousehold.rawValue,
                   lookalikeAccount.rawValue, "unrelated"]

        XCTAssertEqual(NotificationPlan.identifiers(in: all, scope: .account(scope)),
                       [mine.rawValue, sameAccountOtherHousehold.rawValue].sorted())
        XCTAssertEqual(NotificationPlan.identifiers(
            in: all, scope: .household(accountScope: scope, householdID: household)),
                       [mine.rawValue])
    }

    private func scheduled(_ request: ReminderRequest) -> ScheduledReminder {
        ScheduledReminder(identifier: request.identifier.rawValue, fireDay: request.fireDay,
                          hour: request.hour)
    }
}
