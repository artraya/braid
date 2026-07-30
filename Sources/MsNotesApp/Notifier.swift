import Foundation
import UserNotifications

/// macOS notifications ("Note ready", failures, the R16 warning).
/// UNUserNotificationCenter requires a real bundle — every call is guarded so
/// the CLI verification modes never touch it.
enum Notifier {
    private static var available: Bool {
        Bundle.main.bundleIdentifier == "no.msnotes.app"
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard available else {
            print("[notification] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
