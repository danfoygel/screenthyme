import Foundation
import ThymeCore
import UserNotifications

/// Local notifications on parent devices: alerts fetched by a participant (the owner gets CloudKit's visible push
/// instead) and health issues found on refresh.
enum Notifier {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(_ alert: AlertRecord) {
        post(id: alert.id.uuidString, title: alert.title, body: alert.body)
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
