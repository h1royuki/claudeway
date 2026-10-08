import Foundation
import UserNotifications
import SwitcherCore

/// A banner is emitted only after successful switching and only for actual changes.
@MainActor final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    override init() {
        super.init()
        center.delegate = self
    }
    func post(_ report: SessionTransferReport, account: String) {
        guard let body = report.notificationBody else { return }
        Task {
            let settings = await center.notificationSettings()
            do {
                switch settings.authorizationStatus {
                case .notDetermined:
                    guard try await center.requestAuthorization(options: [.alert]) else { return }
                case .authorized, .provisional: break
                default: return // Respect the user's macOS notification preference.
                }
                let content = UNMutableNotificationContent()
                content.title = L10n.text("Chats transferred")
                content.subtitle = L10n.text("Account “%@”", account)
                content.body = body
                content.threadIdentifier = "chat-transfers"
                // No sound, badge, skipped counter, chat titles or filesystem paths.
                let request = UNNotificationRequest(identifier: "chat-transfer-" + UUID().uuidString, content: content, trigger: nil)
                try await center.add(request)
            } catch {
                // Notification delivery must not undo a successful account switch.
                NSLog("Claudeway: could not deliver the chat-transfer notification.")
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
