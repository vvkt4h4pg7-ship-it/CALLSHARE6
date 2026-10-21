import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onOpenSMS: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

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

    func sendSMS(sender: String, body: String, messageID: String) {
        let content = UNMutableNotificationContent()
        content.title = "CALLSHARE — SMS · \(sender)"
        content.body = body.isEmpty ? "New SMS received on J7" : body
        content.sound = .default
        content.userInfo = ["callshare.smsID": messageID]
        let request = UNNotificationRequest(
            identifier: "callshare.sms.\(messageID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let messageID = response.notification.request.content.userInfo["callshare.smsID"] as? String
        if let messageID {
            DispatchQueue.main.async { [weak self] in self?.onOpenSMS?(messageID) }
        }
        completionHandler()
    }
}
