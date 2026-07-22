import AppKit

/// Plays the short sounds associated with the completion reminder countdown.
/// The urgent warning is intentionally made from several system alert beeps so
/// it does not require bundling an audio asset or requesting another permission.
@MainActor
final class ReminderSoundService {
    static let shared = ReminderSoundService()

    private var urgentTask: Task<Void, Never>?

    private init() {}

    func playCompletion() {
        NSSound.beep()
    }

    func playUrgentWarning() {
        urgentTask?.cancel()
        urgentTask = Task { @MainActor [weak self] in
            for index in 0..<8 {
                guard !Task.isCancelled else { return }
                NSSound.beep()
                if index < 7 {
                    try? await Task.sleep(for: .seconds(2))
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
