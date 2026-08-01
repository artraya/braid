import Foundation
import UserNotifications

/// macOS notifications ("Note ready", failures, the R16 warning, speakers to
/// name). UNUserNotificationCenter requires a real bundle — every call is
/// guarded so the CLI verification modes never touch it.
enum Notifier {
    private static var available: Bool {
        Bundle.main.bundleIdentifier == "no.braid.app"
    }

    /// Set by StatusItemController: open the panel at the naming view.
    @MainActor static var onOpenNaming: ((String) -> Void)?
    /// Set by AppState: apply the 1:1 candidate name (user just confirmed it).
    @MainActor static var onApplyName: ((String) -> Void)?

    private static let speakersCategory = "no.braid.speakers"
    private static let applyAction = "no.braid.speakers.apply"
    private static let delegate = Delegate()

    static func requestPermission() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // The Apply title is static (category registration); the name itself
        // travels in the notification body.
        let apply = UNNotificationAction(identifier: applyAction, title: "Apply name")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: speakersCategory, actions: [apply],
                                   intentIdentifiers: []),
        ])
        center.delegate = delegate
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

    /// The "speakers to name" notification. Clicking it opens the naming view;
    /// when `offerApply` is set (the 1:1 case) it also carries an Apply button,
    /// so the common one-on-one call is named in a single click.
    static func notifySpeakers(sessionID: String, title: String, body: String,
                               offerApply: Bool) {
        guard available else {
            print("[notification] \(title): \(body)\(offerApply ? " [Apply]" : "")")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionID": sessionID]
        if offerApply {
            content.categoryIdentifier = speakersCategory
        }
        let request = UNNotificationRequest(
            identifier: "speakers-\(sessionID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Stateless; `@unchecked` only because NSObject blocks synthesised Sendable.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        /// Braid is a menu-bar app, so it can be "active" while the user is in
        /// another window entirely — banners must still show.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let userInfo = response.notification.request.content.userInfo
            let action = response.actionIdentifier
            if let sessionID = userInfo["sessionID"] as? String {
                Task { @MainActor in
                    if action == Notifier.applyAction {
                        Notifier.onApplyName?(sessionID)
                    } else if action == UNNotificationDefaultActionIdentifier {
                        Notifier.onOpenNaming?(sessionID)
                    }
                }
            }
            completionHandler()
        }
    }
}
