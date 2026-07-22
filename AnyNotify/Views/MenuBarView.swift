import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        Toggle("监控任务状态", isOn: Binding(
            get: { store.isMonitoring },
            set: { store.setMonitoring($0) }
        ))

        Divider()
        Label(
            store.claudeAvailable ? "Claude Code：可用" : "Claude Code：未发现",
            systemImage: store.claudeAvailable ? "checkmark.circle.fill" : "circle.dashed"
        )
        Label(
            store.codexAvailable ? "Codex：可用" : "Codex：未发现",
            systemImage: store.codexAvailable ? "checkmark.circle.fill" : "circle.dashed"
        )

        Divider()
        Menu("提醒时长：\(store.reminderDurationMinutes) 分钟") {
            Button("减少 1 分钟") {
                store.reminderDurationMinutes -= 1
            }
            .disabled(store.reminderDurationMinutes == MonitorStore.reminderDurationRange.lowerBound)

            Button("增加 1 分钟") {
                store.reminderDurationMinutes += 1
            }
            .disabled(store.reminderDurationMinutes == MonitorStore.reminderDurationRange.upperBound)

            Divider()
            ForEach([1, 3, 5, 10, 15, 30, 60], id: \.self) { minutes in
                Button(store.reminderDurationMinutes == minutes ? "✓ \(minutes) 分钟" : "\(minutes) 分钟") {
                    store.reminderDurationMinutes = minutes
                }
            }
        }

        Button(store.claudeHooksInstalled ? "卸载 Claude Hooks" : "安装 Claude Hooks") {
            store.toggleClaudeHooks()
        }
        Button("发送测试提醒") {
            store.sendTestNotification()
        }

        if let event = store.events.first {
            Divider()
            Label(shortTitle(event), systemImage: event.status.systemImage)
        }

        Divider()
        if let lastError = store.lastError {
            Text(lastError)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func shortTitle(_ event: TaskEvent) -> String {
        let title = "\(event.source.displayName) \(event.status.displayName)"
        return title.count <= 30 ? title : String(title.prefix(27)) + "…"
    }
}
