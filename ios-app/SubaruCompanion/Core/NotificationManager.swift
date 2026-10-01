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
    }

    func requestPermission() async {
        // .criticalAlert csak Apple entitlementtel működik, anélkül az iOS figyelmen kívül hagyja.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        criticalAllowed = await center.notificationSettings().criticalAlertSetting == .enabled
    }

    /// - Parameter throttle: ugyanazzal a kulccsal ennyi időn belül nem küld újra.
    func send(key: String, title: String, body: String, level: Level = .normal,
              throttle: TimeInterval = 0) {
        if throttle > 0, let last = lastSent[key], Date().timeIntervalSince(last) < throttle { return }
        lastSent[key] = Date()

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
        let request = UNNotificationRequest(identifier: key + "-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        center.add(request)
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
