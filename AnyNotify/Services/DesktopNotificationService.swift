import UserNotifications

protocol NotificationSending: AnyObject {
    func requestAuthorization() async -> UNAuthorizationStatus
    func send(_ event: TaskEvent, includeDetails: Bool) async throws
}

enum DesktopNotificationError: LocalizedError {
    case authorizationDenied
    case authorizationNotDetermined
    case deliveryFailed(Error)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "AnyNotify 没有发送通知的权限，请在“系统设置 → 通知”中允许通知。"
        case .authorizationNotDetermined:
            return "AnyNotify 尚未获得通知权限，请先允许通知后重试。"
        case .deliveryFailed(let error):
            return "系统通知发送失败：\(error.localizedDescription)"
        }
    }
}

final class DesktopNotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationSending {
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

    func send(_ event: TaskEvent, includeDetails: Bool) async throws {
        let center = UNUserNotificationCenter.current()
        let authorizationStatus = await center.notificationSettings().authorizationStatus
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            throw DesktopNotificationError.authorizationDenied
        case .notDetermined:
            throw DesktopNotificationError.authorizationNotDetermined
        @unknown default:
            throw DesktopNotificationError.authorizationDenied
        }

        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.body = event.notificationBody(includeDetails: includeDetails)
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
        do {
            try await center.add(request)
        } catch {
            throw DesktopNotificationError.deliveryFailed(error)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
