import Foundation
import Combine
import Testing
import UserNotifications
@testable import AnyNotify

struct AnyNotifyTests {
    private final class TestNotificationService: NotificationSending {
        var error: Error?
        var sent: [(TaskEvent, Bool)] = []

        func requestAuthorization() async -> UNAuthorizationStatus {
            .authorized
        }

        func send(_ event: TaskEvent, includeDetails: Bool) async throws {
            if let error { throw error }
            sent.append((event, includeDetails))
        }
    }

    private struct TestNotificationError: LocalizedError {
        var errorDescription: String? { "测试发送失败" }
    }

    @Test func claudeCompletionIsParsed() throws {
        var parser = ClaudeLogParser()
        _ = parser.parse(line: try jsonData([
            "type": "user",
            "uuid": "user-1",
            "sessionId": "session-1",
            "cwd": "/tmp/sample",
            "entrypoint": "cli",
            "isSidechain": false,
            "timestamp": "2026-07-22T10:00:00.000Z",
            "message": ["role": "user", "content": "完成这个任务"]
        ]))

        let events = parser.parse(line: try jsonData([
            "type": "assistant",
            "sessionId": "session-1",
            "cwd": "/tmp/sample",
            "entrypoint": "cli",
            "isSidechain": false,
            "timestamp": "2026-07-22T10:00:01.000Z",
            "message": [
                "role": "assistant",
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": "任务完成"]]
            ]
        ]))

        #expect(events.count == 1)
        #expect(events.first?.status == .completed)
        #expect(events.first?.summary == "任务完成")
        #expect(events.first?.projectName == "sample")
    }

    @Test func codexWaitAndAbortAreParsed() throws {
        var parser = CodexLogParser()
        _ = parser.parse(line: try envelope(type: "session_meta", payload: [
            "type": "session_meta",
            "session_id": "session-2",
            "cwd": "/tmp/codex-project",
            "source": "cli"
        ]))
        _ = parser.parse(line: try envelope(type: "event_msg", payload: [
            "type": "task_started",
            "turn_id": "turn-1"
        ]))

        let waiting = parser.parse(line: try envelope(type: "response_item", payload: [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": "call-1",
            "arguments": "{\"questions\":[{\"question\":\"是否继续？\"}]}"
        ]))
        #expect(waiting.first?.status == .waiting)
        #expect(waiting.first?.summary == "是否继续？")

        let interrupted = parser.parse(line: try envelope(type: "event_msg", payload: [
            "type": "turn_aborted",
            "turn_id": "turn-1",
            "reason": "用户中断"
        ]))
        #expect(interrupted.first?.status == .interrupted)
        #expect(interrupted.first?.turnID == "turn-1")
    }

    @Test func subagentsDoNotNotify() throws {
        var parser = CodexLogParser()
        _ = parser.parse(line: try envelope(type: "session_meta", payload: [
            "type": "session_meta",
            "session_id": "sub-session",
            "cwd": "/tmp/project",
            "thread_source": "subagent"
        ]))
        let events = parser.parse(line: try envelope(type: "event_msg", payload: [
            "type": "task_complete",
            "turn_id": "turn-sub",
            "last_agent_message": "完成"
        ]))
        #expect(events.isEmpty)
    }

    @Test func completionReminderCountsDownForThreeMinutes() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reminder = CompletionReminder(source: .claude, startedAt: start)

        #expect(reminder.remainingSeconds(at: start) == 180)
        #expect(reminder.remainingSeconds(at: start.addingTimeInterval(60)) == 120)
        #expect(reminder.isOverdue(at: start.addingTimeInterval(179)) == false)
        #expect(reminder.isOverdue(at: start.addingTimeInterval(180)) == true)
        #expect(reminder.remainingSeconds(at: start.addingTimeInterval(181)) == 0)
        #expect(reminder.overdueSeconds(at: start.addingTimeInterval(179)) == 0)
        #expect(reminder.overdueSeconds(at: start.addingTimeInterval(180)) == 0)
        #expect(reminder.overdueSeconds(at: start.addingTimeInterval(181)) == 1)
    }

    @Test func completionReminderSupportsCustomDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reminder = CompletionReminder(
            source: .codex,
            startedAt: start,
            duration: 10 * 60
        )

        #expect(reminder.remainingSeconds(at: start) == 600)
        #expect(reminder.updatingDuration(5 * 60).remainingSeconds(at: start) == 300)
    }

    @MainActor
    @Test func reminderDurationIsPersistedAndUpdatesCurrentReminder() {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(preferences: preferences)
        store.previewCompletionReminder(source: .claude)
        let start = store.completionReminder?.startedAt
        store.reminderDurationMinutes = 8

        #expect(store.completionReminder?.deadline == start?.addingTimeInterval(8 * 60))
        #expect(MonitorStore(preferences: preferences).reminderDurationMinutes == 8)
    }

    @MainActor
    @Test func unchangedAvailabilityDoesNotRepublishMenuState() {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(preferences: preferences)
        var publicationCount = 0
        let observation = store.objectWillChange.sink {
            publicationCount += 1
        }

        store.applyAvailability(claude: false, codex: false)
        #expect(publicationCount == 0)

        store.applyAvailability(claude: true, codex: false)
        #expect(publicationCount == 1)

        store.applyAvailability(claude: true, codex: false)
        #expect(publicationCount == 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test func dismissingCompletionReminderClearsIt() {
        let preferences = UserDefaults(suiteName: "AnyNotifyTests.\(UUID().uuidString)")!
        let store = MonitorStore(preferences: preferences)
        store.previewCompletionReminder(source: .claude)

        store.dismissCompletionReminder()

        #expect(store.completionReminder == nil)
    }

    @MainActor
    @Test func monitoringPreferenceIsPersisted() {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(preferences: preferences)
        #expect(store.isMonitoring)
        store.setMonitoring(false)

        #expect(!MonitorStore(preferences: preferences).isMonitoring)
        store.setMonitoring(true)
        #expect(MonitorStore(preferences: preferences).isMonitoring)
    }

    @MainActor
    @Test func pausedStoreStillReportsClaudeHookInstallation() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "AnyNotifyTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let settingsURL = temporaryDirectory.appending(path: "settings.json")
        let manager = ClaudeHookManager(settingsURL: settingsURL)
        try manager.install()

        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(false, forKey: "monitoringEnabled")

        let store = MonitorStore(preferences: preferences, hookManager: manager)
        #expect(!store.isMonitoring)
        #expect(store.claudeHooksInstalled)
    }

    @MainActor
    @Test func pausedMonitoringIgnoresHookEvents() async throws {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let service = TestNotificationService()
        let store = MonitorStore(preferences: preferences, notifications: service)
        store.setMonitoring(false)

        store.handle(url: try #require(URL(string: "anynotify://hook?source=claude&status=completed")))
        try await Task.sleep(for: .milliseconds(20))

        #expect(service.sent.isEmpty)
        #expect(store.completionReminder == nil)
    }

    @MainActor
    @Test func notificationFailureIsShownToUser() async throws {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let service = TestNotificationService()
        service.error = TestNotificationError()
        let store = MonitorStore(preferences: preferences, notifications: service)

        store.handle(url: try #require(URL(string: "anynotify://hook?source=claude&status=completed")))
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.lastError?.contains("发送通知失败") == true)
    }

    @MainActor
    @Test func notificationDetailsAreHiddenByDefaultAndOptInIsPersisted() async throws {
        let suiteName = "AnyNotifyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let service = TestNotificationService()
        let store = MonitorStore(preferences: preferences, notifications: service)

        store.handle(url: try #require(URL(string: "anynotify://hook?source=claude&status=completed")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.sent.last?.1 == false)
        #expect(!MonitorStore(preferences: preferences).showNotificationDetails)

        store.showNotificationDetails = true
        #expect(MonitorStore(preferences: preferences).showNotificationDetails)
    }

    @Test func notificationSummaryRedactsSecrets() {
        let event = TaskEvent(
            source: .claude,
            status: .completed,
            workingDirectory: "/tmp/project",
            summary: "token=super-secret sk-1234567890abcdef password=hunter2"
        )

        #expect(event.notificationBody == "任务状态已更新")
        let body = event.notificationBody(includeDetails: true)
        #expect(body.contains("[已隐藏]"))
        #expect(!body.contains("super-secret"))
        #expect(!body.contains("1234567890abcdef"))
        #expect(!body.contains("hunter2"))
    }

    @Test func claudeHookInstallBacksUpValidConfigurationAndLocks() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "AnyNotifyTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let settingsURL = temporaryDirectory.appending(path: "settings.json")
        let original = Data("{\"custom\":true}\n".utf8)
        try original.write(to: settingsURL)
        let manager = ClaudeHookManager(settingsURL: settingsURL)

        try manager.install()

        #expect(try Data(contentsOf: settingsURL.appendingPathExtension("anynotify.backup")) == original)
        #expect(fileManager.fileExists(atPath: settingsURL.appendingPathExtension("anynotify.lock").path))
        #expect(manager.isInstalled())
    }

    @Test func claudeHookInstallRefusesToOverwriteInvalidConfiguration() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "AnyNotifyTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let settingsURL = temporaryDirectory.appending(path: "settings.json")
        let invalid = Data("{not-json".utf8)
        try invalid.write(to: settingsURL)
        let manager = ClaudeHookManager(settingsURL: settingsURL)

        var didThrow = false
        do {
            try manager.install()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: settingsURL) == invalid)
        #expect(!fileManager.fileExists(atPath: settingsURL.appendingPathExtension("anynotify.backup").path))
    }

    @MainActor
    @Test func startedHookDismissesCompletionReminder() async throws {
        let preferences = UserDefaults(suiteName: "AnyNotifyTests.\(UUID().uuidString)")!
        let store = MonitorStore(preferences: preferences)
        store.previewCompletionReminder(source: .codex)

        store.handle(url: try #require(URL(string: "anynotify://hook?source=codex&status=started")))
        try await Task.sleep(for: .milliseconds(10))

        #expect(store.completionReminder == nil)
    }

    @Test func logMonitoringCacheIsBounded() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appending(path: "AnyNotifyTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        let claudeRoot = temporaryHome
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        try fileManager.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        for index in 0..<8 {
            let file = claudeRoot.appending(path: "session-\(index).jsonl")
            try Data("{\"type\":\"noop\"}\n".utf8).write(to: file)
        }

        let engine = LogMonitoringEngine(
            homeDirectory: temporaryHome,
            maximumTrackedFiles: 4
        )
        _ = await engine.poll()
        let counts = await engine.cachedStateCounts()

        #expect(counts.cursors == 4)
        #expect(counts.claudeParsers == 4)
        #expect(counts.codexParsers == 0)
    }

    @Test func logFileDiscoveryIsThrottled() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appending(path: "AnyNotifyTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        let claudeRoot = temporaryHome
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        try fileManager.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try Data("{\"type\":\"noop\"}\n".utf8)
            .write(to: claudeRoot.appending(path: "first.jsonl"))

        let start = Date(timeIntervalSince1970: 1_000)
        let engine = LogMonitoringEngine(homeDirectory: temporaryHome, discoveryInterval: 10)
        _ = await engine.poll(at: start)

        try Data("{\"type\":\"noop\"}\n".utf8)
            .write(to: claudeRoot.appending(path: "second.jsonl"))
        _ = await engine.poll(at: start.addingTimeInterval(9))
        var counts = await engine.cachedStateCounts()
        #expect(counts.cursors == 1)

        _ = await engine.poll(at: start.addingTimeInterval(10))
        counts = await engine.cachedStateCounts()
        #expect(counts.cursors == 2)
    }

    @Test func applicationDataStorePersistsDedupeAndClearsOnlyLocalRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AnyNotifyStore.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let event = TaskEvent(source: .codex, status: .completed, sessionID: "s1", turnID: "t1", summary: "完成", timestamp: timestamp)
        let store = ApplicationDataStore(rootDirectory: root)
        #expect(await store.prepare(event, now: timestamp) != nil)
        await store.record(event, notificationResult: "sent", now: timestamp)

        let restored = ApplicationDataStore(rootDirectory: root)
        #expect(await restored.prepare(event, now: timestamp.addingTimeInterval(1)) == nil)
        _ = await restored.clearLocalRecords()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "EventHistory.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    private func envelope(type: String, payload: [String: Any]) throws -> Data {
        try jsonData([
            "type": type,
            "timestamp": "2026-07-22T10:00:00.000Z",
            "payload": payload
        ])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
