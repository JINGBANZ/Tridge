import Foundation
import UserNotifications

/// Local expiry notifications: two per item — T−2 days ("{uuid}-pre") and expiry
/// day ("{uuid}-day") — at the hour configured in Settings.
enum NotificationService {
    /// Ask for permission on first successful item add, not at launch.
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func schedule(for item: FridgeItem, hour: Int, calendar: Calendar = .current) {
        cancel(for: item.id)
        guard item.status == .active else { return }
        let center = UNUserNotificationCenter.current()

        func add(id suffix: String, on day: Date, body: String) {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            guard let fireDate = calendar.date(from: components), fireDate > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = "What's In My Fridge"
            content.body = body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(item.id.uuidString)-\(suffix)",
                                             content: content, trigger: trigger))
        }

        let art = Artwork.artwork(for: item)
        if let preDay = calendar.date(byAdding: .day, value: -2, to: item.expiryDate) {
            add(id: "pre", on: preDay, body: "\(art) \(item.name) expires in 2 days.")
        }
        add(id: "day", on: item.expiryDate, body: "\(art) \(item.name) expires today — eat it!")
    }

    static func cancel(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["\(id.uuidString)-pre", "\(id.uuidString)-day"])
    }

    /// App icon badge = count of expired active items.
    static func updateBadge(expiredCount: Int) {
        UNUserNotificationCenter.current().setBadgeCount(expiredCount)
    }
}
