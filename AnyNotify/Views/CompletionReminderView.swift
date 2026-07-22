import SwiftUI

struct CompletionReminderView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let reminder = store.completionReminder {
                reminderContent(reminder, at: context.date)
            }
        }
        .frame(width: 300, height: 176)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .allowsWindowActivationEvents(true)
    }

    private func reminderContent(_ reminder: CompletionReminder, at date: Date) -> some View {
        let overdue = reminder.isOverdue(at: date)
        let remainingSeconds = reminder.remainingSeconds(at: date)
        let overdueSeconds = reminder.overdueSeconds(at: date)
        let urgent = !overdue && remainingSeconds <= 30

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: reminder.source.systemImage)
                    .foregroundStyle(overdue || urgent ? .red : .green)
                Text("\(reminder.source.displayName) 任务已完成")
                    .font(.headline)
                Spacer()
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            CountdownDisplay(
                text: overdue ? "已超时 \(overdueSeconds) 秒" : formattedTime(remainingSeconds),
                urgent: urgent,
                overdue: overdue
            )

            Text(overdue ? "任务已经完成，快回来继续处理" : "快来继续干活，别忘了任务已经完成")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                store.dismissCompletionReminder()
            } label: {
                Label("我知道了", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func formattedTime(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

private struct CountdownDisplay: View {
    let text: String
    let urgent: Bool
    let overdue: Bool

    @State private var isPulsing = false

    var body: some View {
        Text(text)
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(countsDown: !overdue))
            .foregroundStyle(overdue || urgent ? .red : .primary)
            .scaleEffect(urgent ? (isPulsing ? 1.12 : 0.96) : 1)
            .shadow(
                color: urgent ? .red.opacity(isPulsing ? 0.85 : 0.25) : .clear,
                radius: urgent ? (isPulsing ? 14 : 3) : 0
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .animation(
                urgent
                    ? .easeInOut(duration: 0.28).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: isPulsing
            )
            .onAppear {
                updatePulse()
            }
            .onChange(of: urgent) {
                updatePulse()
            }
    }

    private func updatePulse() {
        if urgent {
            isPulsing = false
            Task { @MainActor in
                isPulsing = true
            }
        } else {
            isPulsing = false
        }
    }
}
