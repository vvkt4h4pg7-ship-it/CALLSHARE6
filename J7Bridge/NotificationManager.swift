import Foundation
import UserNotifications

final class NotificationManager {
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendMissedCall(number: String, name: String?) {
        let content = UNMutableNotificationContent()
        content.title = "J7Bridge — Missed Call"
        content.body = name ?? number
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "j7bridge.missed.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    func sendSMS(sender: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "CALLSHARE — SMS · \(sender)"
        content.body = body.isEmpty ? "New SMS received on J7" : body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "callshare.sms.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

}
