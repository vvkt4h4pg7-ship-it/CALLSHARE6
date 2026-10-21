import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onSMSNotificationTap: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
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

    func sendSMS(sender: String, body: String, messageID: String, conversationID: String) {
        let content = UNMutableNotificationContent()
        content.title = "CALLSHARE — SMS · \(sender)"
        content.body = body.isEmpty ? "New SMS received on J7" : body
        content.sound = .default
        content.userInfo = ["messageID": messageID, "conversationID": conversationID]
        let request = UNNotificationRequest(
            identifier: "callshare.sms.\(messageID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if response.notification.request.identifier.hasPrefix("callshare.sms."),
           let conversationID = userInfo["conversationID"] as? String {
            DispatchQueue.main.async { [weak self] in self?.onSMSNotificationTap?(conversationID) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}
