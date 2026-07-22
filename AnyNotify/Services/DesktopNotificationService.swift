import UserNotifications

final class DesktopNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DesktopNotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return await center.notificationSettings().authorizationStatus
    }

    func send(_ event: TaskEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.body = event.notificationBody
        content.sound = .default
        content.userInfo = [
            "source": event.source.rawValue,
            "status": event.status.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "anynotify-\(event.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
