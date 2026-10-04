import Foundation
import UserNotifications

/// One reminder ready for the system: the pure plan plus its local copy.
///
/// The copy is built here and never leaves the device — reminder bodies name
/// the item, which is exactly what diagnostics may not.
struct PreparedReminder: Equatable, Sendable {
    let identifier: String
    let fireDay: InventoryDay
    let hour: Int
    let title: String
    let body: String
}

/// The slice of `UNUserNotificationCenter` the reconciler needs, so the diff can
/// be driven in tests without the real notification centre.
protocol NotificationScheduling: Sendable {
    func isAuthorizationUndetermined() async -> Bool
    func requestAuthorization() async
    /// Every pending Tridge-shaped request, reduced to what the diff compares.
    func pendingReminders() async -> [ScheduledReminder]
    /// Identifiers of alerts still sitting in Notification Center.
    func deliveredIdentifiers() async -> [String]
    func schedule(_ reminders: [PreparedReminder], calendar: Calendar)
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
    func setBadge(_ count: Int)
}

/// Keeps the Active Household's expiry reminders and the app badge equal to what
/// the current snapshots imply.
///
/// Every rule about *which* reminders should exist lives in the Linux-tested
/// `NotificationPlan`; this is only the Apple-platform adapter that applies its
/// diff. Reminders cover the Active Household only, so account and Household
/// transitions carry the exact old identifier prefix in and retire both pending
/// requests and alerts already delivered.
@MainActor
final class ReminderReconciler {
    /// Where the user's reminder hour lives — the same key Settings binds to.
    static let reminderHourKey = "notificationHour"
    static let defaultHour = 9

    private let center: any NotificationScheduling
    private let defaults: UserDefaults
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date

    init(center: any NotificationScheduling = UserNotificationCenterAdapter(),
         defaults: UserDefaults = .standard,
         calendar: @escaping @Sendable () -> Calendar = { .current },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.center = center
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    var reminderHour: Int {
        defaults.object(forKey: Self.reminderHourKey) as? Int ?? Self.defaultHour
    }

    /// Asked on the first successful add, not at launch — and never again from
    /// a remote import, which the user did not initiate.
    func requestPermissionIfNeeded() async {
        guard await center.isAuthorizationUndetermined() else { return }
        await center.requestAuthorization()
    }

    /// Brings the Active Household's reminders and badge in line with `items`.
    ///
    /// Only the difference is applied: an unchanged item keeps the request it
    /// already has, so reconciliation after every save and import does not churn
    /// the whole schedule.
    func reconcile(items: [InventoryItemSnapshot], accountScope: AccountScopeHash,
                   householdID: UUID) async {
        let calendar = self.calendar()
        let today = InventoryDay.today(in: calendar, now: now())
        let currentHour = calendar.component(.hour, from: now())
        let hour = reminderHour

        let desired = NotificationPlan.desiredRequests(
            items: items, accountScope: accountScope.value, householdID: householdID,
            hour: hour, today: today, currentHour: currentHour)
        let diff = NotificationPlan.diff(
            desired: desired, pending: await center.pendingReminders(),
            scope: .household(accountScope: accountScope.value, householdID: householdID))

        if !diff.remove.isEmpty {
            center.removePending(identifiers: diff.remove)
        }
        // An update is a reschedule: adding a request under an existing
        // identifier replaces it, so the old fire date cannot survive an hour
        // change.
        let scheduled = (diff.add + diff.update).compactMap { request in
            prepared(request, items: items)
        }
        if !scheduled.isEmpty {
            center.schedule(scheduled, calendar: calendar)
        }
        center.setBadge(items.filter { $0.isExpired(on: today) }.count)
    }

    /// Retires everything belonging to an account or Household the app is
    /// leaving — pending requests *and* alerts already in Notification Center,
    /// which would otherwise keep naming a fridge the user can no longer open.
    ///
    /// The scope is matched structurally, so another current Household's
    /// reminders are never swept up by a shared prefix.
    func retire(scope: ReminderScope) async {
        let pending = await center.pendingReminders().map(\.identifier)
        let obsoletePending = NotificationPlan.identifiers(in: pending, scope: scope)
        if !obsoletePending.isEmpty {
            center.removePending(identifiers: obsoletePending)
        }

        let delivered = await center.deliveredIdentifiers()
        let obsoleteDelivered = NotificationPlan.identifiers(in: delivered, scope: scope)
        if !obsoleteDelivered.isEmpty {
            center.removeDelivered(identifiers: obsoleteDelivered)
        }
    }

    /// Clears the badge without touching any schedule — used when inventory
    /// stops being visible at all.
    func clearBadge() {
        center.setBadge(0)
    }

    private func prepared(_ request: ReminderRequest,
                          items: [InventoryItemSnapshot]) -> PreparedReminder? {
        guard let item = items.first(where: { $0.id == request.identifier.itemID }) else {
            return nil
        }
        let emojiFree = defaults.bool(forKey: "emojiFreeMode")
        let art = emojiFree ? "" : Artwork.emoji(forKey: item.artKey) + " "
        let body = request.identifier.kind == .pre
            ? "\(art)\(item.name) expires in \(NotificationPlan.warningLeadDays) days."
            : "\(art)\(item.name) expires today — eat it!"
        return PreparedReminder(identifier: request.identifier.rawValue,
                                fireDay: request.fireDay, hour: request.hour,
                                title: "Tridge", body: body)
    }
}

/// The real notification centre.
struct UserNotificationCenterAdapter: NotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func isAuthorizationUndetermined() async -> Bool {
        await center.notificationSettings().authorizationStatus == .notDetermined
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func pendingReminders() async -> [ScheduledReminder] {
        await center.pendingNotificationRequests().compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else {
                return nil
            }
            let parts = trigger.dateComponents
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let hour = parts.hour, let fireDay = InventoryDay(year: year, month: month,
                                                                    day: day)
            else { return nil }
            return ScheduledReminder(identifier: request.identifier, fireDay: fireDay, hour: hour)
        }
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func schedule(_ reminders: [PreparedReminder], calendar: Calendar) {
        for reminder in reminders {
            let civil = reminder.fireDay.components
            var parts = DateComponents()
            parts.calendar = calendar
            parts.year = civil.year
            parts.month = civil.month
            parts.day = civil.day
            parts.hour = reminder.hour

            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.identifier,
                                             content: content, trigger: trigger))
        }
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }
}

/// Removes the notifications and badge an earlier build scheduled. Injected so
/// the upgrade can be driven without a notification center.
protocol LegacyEffectsCleaning: Sendable {
    func clearScheduledAndDeliveredNotifications()
}

/// The upgrade's one-time cleanup: an installation that carried
/// `{uuid}-pre`/`{uuid}-day` reminders must stop firing them for an inventory
/// that has moved, and the new identifiers are account- and household-scoped, so
/// nothing else could remove them.
///
/// It runs before iCloud is even checked, which is why it takes everything
/// rather than a computed set: a signed-out or restricted upgrade would
/// otherwise keep notifying while the migration waits for an account.
struct UserNotificationLegacyEffects: LegacyEffectsCleaning {
    func clearScheduledAndDeliveredNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }
}
