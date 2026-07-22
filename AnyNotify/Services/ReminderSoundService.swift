import AppKit

/// Plays the short sounds associated with the completion reminder countdown.
/// The urgent warning is intentionally made from several system alert beeps so
/// it does not require bundling an audio asset or requesting another permission.
@MainActor
final class ReminderSoundService {
    static let shared = ReminderSoundService()

    private var urgentTask: Task<Void, Never>?

    private init() {}

    func playUrgentWarning() {
        urgentTask?.cancel()
        urgentTask = Task { @MainActor [weak self] in
            for index in 0..<3 {
                guard !Task.isCancelled else { return }
                NSSound.beep()
                if index < 2 {
                    try? await Task.sleep(for: .milliseconds(180))
                }
            }
            self?.urgentTask = nil
        }
    }

    func playFinished() {
        urgentTask?.cancel()
        urgentTask = nil
        NSSound.beep()
    }

    func stop() {
        urgentTask?.cancel()
        urgentTask = nil
    }
}
