import Foundation

struct CompletionReminder: Equatable, Sendable {
    static let defaultDuration: TimeInterval = 3 * 60

    let id: UUID
    let source: TaskSource
    let startedAt: Date
    let duration: TimeInterval
    let deadline: Date

    init(
        source: TaskSource,
        startedAt: Date = Date(),
        duration: TimeInterval = Self.defaultDuration,
        id: UUID = UUID()
    ) {
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.duration = duration
        self.deadline = startedAt.addingTimeInterval(duration)
    }

    func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    func isOverdue(at date: Date) -> Bool {
        date >= deadline
    }

    func updatingDuration(_ duration: TimeInterval) -> CompletionReminder {
        CompletionReminder(
            source: source,
            startedAt: startedAt,
            duration: duration,
            id: id
        )
    }
}
