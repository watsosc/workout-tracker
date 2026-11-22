import Foundation
import UserNotifications

/// Schedules a local notification for when rest is over, so the phone can stay in a pocket.
@MainActor
final class RestTimerNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RestTimerNotifier()

    private let center = UNUserNotificationCenter.current()
    private let requestId = "workout.rest-timer"

    /// Call once at launch so notifications also show while the app is open.
    func install() {
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func scheduleRestEnd(after seconds: Int, nextSet: String) {
        cancel()
        guard seconds > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest's up"
        content.body = "Next: \(nextSet)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [requestId])
        center.removeDeliveredNotifications(withIdentifiers: [requestId])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
