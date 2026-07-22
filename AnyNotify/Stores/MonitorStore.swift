import Foundation
import Combine
import UserNotifications

@MainActor
final class MonitorStore: ObservableObject {
    static let reminderDurationRange = 1...60
    static let defaultReminderDurationMinutes = 3

    @Published var isMonitoring = true
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var claudeAvailable = false
    @Published private(set) var codexAvailable = false
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var completionReminder: CompletionReminder?
    @Published var reminderDurationMinutes: Int {
        didSet {
            let normalized = Self.normalizedReminderDuration(reminderDurationMinutes)
            if normalized != reminderDurationMinutes {
                reminderDurationMinutes = normalized
                return
            }
            preferences.set(reminderDurationMinutes, forKey: Self.reminderDurationKey)
            if let completionReminder {
                let updatedReminder = completionReminder.updatingDuration(reminderDuration)
                self.completionReminder = updatedReminder
                scheduleReminderSounds(for: updatedReminder)
            }
        }
    }
    @Published var lastError: String?

    private let engine = LogMonitoringEngine()
    private let notifications = DesktopNotificationService.shared
    private let reminderSounds = ReminderSoundService.shared
    private let hookManager = ClaudeHookManager()
    private let preferences: UserDefaults
    private var monitorTask: Task<Void, Never>?
    private var reminderSoundTask: Task<Void, Never>?
    private var recentDedupeKeys: [String: Date] = [:]

    private static let reminderDurationKey = "completionReminderDurationMinutes"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let savedDuration = preferences.integer(forKey: Self.reminderDurationKey)
        reminderDurationMinutes = Self.normalizedReminderDuration(
            savedDuration == 0 ? Self.defaultReminderDurationMinutes : savedDuration
        )
    }

    deinit {
        monitorTask?.cancel()
        reminderSoundTask?.cancel()
    }

    func start() {
        guard monitorTask == nil, isMonitoring else { return }
        claudeHooksInstalled = hookManager.isInstalled()
        monitorTask = Task { @MainActor [weak self] in
            await self?.refreshNotificationStatus()
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.pollOnce()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    // Avoid rebuilding an open MenuBarExtra when a poll returns the same state.
    // Repeated publications interrupt pointer tracking in nested menus.
    func applyAvailability(claude: Bool, codex: Bool) {
        if claudeAvailable != claude {
            claudeAvailable = claude
        }
        if codexAvailable != codex {
            codexAvailable = codex
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func setMonitoring(_ enabled: Bool) {
        isMonitoring = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func sendTestNotification() {
        Task {
            notificationStatus = await notifications.requestAuthorization()
            let event = TaskEvent(
                source: .codex,
                status: .completed,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                summary: "AnyNotify 桌面通知测试成功"
            )
            await accept(event)
        }
    }

    #if DEBUG
    func previewCompletionReminder(source: TaskSource) {
        completionReminder = CompletionReminder(source: source)
    }
    #endif

    /// Dismiss the completion reminder when the user has acknowledged it or
    /// when a new task starts and the user is back to work.
    func dismissCompletionReminder() {
        completionReminder = nil
        reminderSoundTask?.cancel()
        reminderSoundTask = nil
        reminderSounds.stop()
    }

    func toggleClaudeHooks() {
        do {
            if claudeHooksInstalled {
                try hookManager.uninstall()
            } else {
                try hookManager.install()
            }
            claudeHooksInstalled = hookManager.isInstalled()
            lastError = nil
        } catch {
            lastError = "更新 Claude Hooks 失败：\(error.localizedDescription)"
        }
    }

    func handle(url: URL) {
        guard url.scheme == "anynotify", url.host == "hook" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let source = TaskSource(rawValue: values["source"] ?? ""),
              let status = TaskStatus(rawValue: values["status"] ?? "") else { return }

        let summary = status == .waiting
            ? "\(source.displayName) 正在等待你的确认或输入"
            : "\(source.displayName) 任务状态已更新"
        Task { await accept(TaskEvent(source: source, status: status, summary: summary)) }
    }

    private func refreshNotificationStatus() async {
        let status = await notifications.requestAuthorization()
        guard !Task.isCancelled else { return }
        notificationStatus = status
    }

    private func pollOnce() async {
        guard isMonitoring else { return }
        let result = await engine.poll()
        guard !Task.isCancelled, isMonitoring else { return }

        applyAvailability(
            claude: result.availability.claude,
            codex: result.availability.codex
        )
        for event in result.events {
            guard !Task.isCancelled else { return }
            await accept(event)
        }
    }

    private func accept(_ event: TaskEvent) async {
        // A new task means the user is actively working again, so the previous
        // completion reminder is no longer useful. Do this before deduplication
        // so even a repeated start event can close a visible reminder.
        if event.status == .started {
            dismissCompletionReminder()
        }

        let now = Date()
        recentDedupeKeys = recentDedupeKeys.filter { now.timeIntervalSince($0.value) < 30 }
        if let date = recentDedupeKeys[event.dedupeKey], now.timeIntervalSince(date) < 10 {
            return
        }

        // Hook 和 JSONL watcher 可能在数秒内报告同一状态；做一次短窗口交叉去重。
        let coarseKey = "\(event.source.rawValue)|\(event.status.rawValue)"
        if let date = recentDedupeKeys[coarseKey], now.timeIntervalSince(date) < 2.5 {
            return
        }
        recentDedupeKeys[event.dedupeKey] = now
        recentDedupeKeys[coarseKey] = now

        if event.status == .completed {
            let reminder = CompletionReminder(
                source: event.source,
                startedAt: now,
                duration: reminderDuration
            )
            completionReminder = reminder
            scheduleReminderSounds(for: reminder)
        }
        await notifications.send(event)
    }

    private func scheduleReminderSounds(for reminder: CompletionReminder) {
        reminderSoundTask?.cancel()
        reminderSoundTask = Task { [weak self] in
            let warningDate = reminder.deadline.addingTimeInterval(-30)
            let now = Date()

            if now < warningDate {
                do {
                    try await Task.sleep(for: .seconds(warningDate.timeIntervalSince(now)))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self?.completionReminder?.id == reminder.id else { return }
            self?.reminderSounds.playUrgentWarning()

            let afterWarning = Date()
            if afterWarning < reminder.deadline {
                do {
                    try await Task.sleep(for: .seconds(reminder.deadline.timeIntervalSince(afterWarning)))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self?.completionReminder?.id == reminder.id else { return }
            self?.reminderSounds.playFinished()
            self?.reminderSoundTask = nil
        }
    }

    private var reminderDuration: TimeInterval {
        TimeInterval(reminderDurationMinutes * 60)
    }

    private static func normalizedReminderDuration(_ minutes: Int) -> Int {
        min(max(minutes, reminderDurationRange.lowerBound), reminderDurationRange.upperBound)
    }
}

extension UNAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined: "尚未请求"
        case .denied: "已关闭"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "临时会话"
        @unknown default: "未知"
        }
    }
}
