import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: MonitorStore
    @State private var showingClearConfirmation = false

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
        Toggle("通知中显示任务摘要", isOn: $store.showNotificationDetails)
        Button("发送测试提醒") {
            store.sendTestNotification()
        }
        Button("清空本地记录…") {
            showingClearConfirmation = true
        }
        .confirmationDialog("清空 AnyNotify 本地记录？", isPresented: $showingClearConfirmation) {
            Button("清空记录", role: .destructive) {
                store.clearLocalRecords()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清空 AnyNotify 保存的事件、任务状态和诊断信息，不会删除 Claude/Codex 原始日志或读取游标。")
        }

        Divider()
        if let lastError = store.lastError {
            Text(lastError)
        }
        if let lastClearMessage = store.lastClearMessage {
            Text(lastClearMessage)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
