import AppKit
import UserNotifications

/// Posts local notifications. Needs the bundled .app; `swift run` has no bundle identifier.
enum Notifier {
    enum Permission { case allowed, denied, notAsked, unavailable }

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }

    static func permission() async -> Permission {
        guard isAvailable else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notAsked
        }
    }

    static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    /// `force` skips the in-app switch, for test notifications. `url` is opened when the notification is clicked.
    /// A notification still shown with the same `id` is replaced, so only the latest news of a kind stays.
    static func post(title: String, body: String?, id: String? = nil, url: URL? = nil, force: Bool = false) {
        guard isAvailable, isEnabled || force else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil))
    }
}
