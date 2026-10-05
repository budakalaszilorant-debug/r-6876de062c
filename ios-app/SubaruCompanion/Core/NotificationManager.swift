import Foundation
import UserNotifications
import UIKit

/// Minden értesítés helyi (UNUserNotificationCenter), internet nélkül.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private var lastSent: [String: Date] = [:]
    /// Csak akkor igaz, ha az Apple critical alert entitlement megvan és a felhasználó engedélyezte.
    private var criticalAllowed = false

    enum Level { case normal, timeSensitive, critical }

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    static let parkedCategory = "PARKED"

    /// A „Leparkoltál” értesítés gombjai: az app megnyitása nélkül indítanak parkolóórát.
    private func registerCategories() {
        let actions = ParkingTimer.presets.map { m in
            UNNotificationAction(identifier: "PARK_\(m)",
                                 title: m % 60 == 0 ? tr("\(m / 60) óra", "\(m / 60) h") : tr("\(m) perc", "\(m) min"),
                                 options: [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.parkedCategory, actions: actions, intentIdentifiers: [])
        ])
    }

    func clearAccountNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        lastSent.removeAll()
    }

    func requestPermission() async {
        // .criticalAlert csak Apple entitlementtel működik, anélkül az iOS figyelmen kívül hagyja.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        criticalAllowed = await center.notificationSettings().criticalAlertSetting == .enabled
    }

    /// - Parameter throttle: ugyanazzal a kulccsal ennyi időn belül nem küld újra.
    func send(key: String, title: String, body: String, level: Level = .normal,
              throttle: TimeInterval = 0, category: String? = nil) {
        let key = CarStore.key(key)
        if throttle > 0, let last = lastSent[key], Date().timeIntervalSince(last) < throttle { return }
        lastSent[key] = Date()
        let content = makeContent(title: title, body: body, level: level)
        if let category { content.categoryIdentifier = category }
        content.userInfo["carId"] = CarStore.activeId
        let request = UNNotificationRequest(identifier: key + "-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        center.add(request)
    }

    /// Későbbre ütemezett értesítés; azonos azonosítóval a korábbit felülírja.
    func schedule(id: String, after seconds: TimeInterval, title: String, body: String, level: Level = .normal) {
        let content = makeContent(title: title, body: body, level: level)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Adott időpontra ütemezett értesítés (lejárati emlékeztetők).
    func schedule(id: String, at date: Date, title: String, body: String, level: Level = .normal) {
        let content = makeContent(title: title, body: body, level: level)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Az adott előtagú függő értesítések törlése, utána `then` fut (a főszálon).
    func cancel(prefix: String, then: @escaping () -> Void) {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            DispatchQueue.main.async(execute: then)
        }
    }

    func cancel(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func makeContent(title: String, body: String, level: Level) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.badge = 1
        // Entitlement nélkül a kritikus értesítés time-sensitive-ként megy ki.
        let effective = (level == .critical && !criticalAllowed) ? Level.timeSensitive : level
        switch effective {
        case .normal:
            content.sound = .default
        case .timeSensitive:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case .critical:
            content.sound = .defaultCritical
            content.interruptionLevel = .critical
        }
        return content
    }

    // Értesítés gombjának megnyomása
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        let action = response.actionIdentifier
        if action.hasPrefix("PARK_"), let minutes = Int(action.dropFirst(5)) {
            DispatchQueue.main.async {
                let carId = response.notification.request.content.userInfo["carId"] as? Int
                ParkingTimer.shared.start(minutes: minutes, carID: carId)
            }
        }
        completion()
    }

    func clearBadge() {
        if #available(iOS 17.0, *) {
            center.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    // Előtérben is jelenjen meg banner formában.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound, .list])
    }
}
