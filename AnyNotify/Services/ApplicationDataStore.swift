import Foundation

actor ApplicationDataStore {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let maximumHistoryCount = 10_000

    struct ClearResult: Sendable {
        let removedFiles: Int
    }

    private struct PersistedState: Codable {
        var tasks: [String: TaskState] = [:]
        var dedupeDates: [String: Date] = [:]
        var activeTasksBySource: [String: ActiveTask] = [:]
    }

    private struct TaskState: Codable {
        var status: TaskStatus
        var timestamp: Date
    }

    private struct ActiveTask: Codable {
        var sessionID: String?
        var turnID: String?
        var timestamp: Date
    }

    private struct HistoryRecord: Codable {
        let event: TaskEvent
        let notificationResult: String
        let recordedAt: Date
    }

    private struct DiagnosticRecord: Codable {
        let category: String
        let message: String
        let sourcePath: String?
        let recordedAt: Date
    }

    let rootDirectory: URL
    private let historyURL: URL
    private let stateURL: URL
    private let diagnosticsDirectory: URL
    private let diagnosticsURL: URL
    private var state: PersistedState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL? = nil) {
        let fileManager = FileManager.default
        let root = rootDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "AnyNotify", directoryHint: .isDirectory)
        self.rootDirectory = root
        historyURL = root.appending(path: "EventHistory.jsonl")
        stateURL = root.appending(path: "TaskState.json")
        diagnosticsDirectory = root.appending(path: "Diagnostics", directoryHint: .isDirectory)
        diagnosticsURL = diagnosticsDirectory.appending(path: "events.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        state = (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(PersistedState.self, from: $0) } ?? PersistedState()
    }

    func prepare(_ incoming: TaskEvent, now: Date = Date()) -> TaskEvent? {
        pruneState(now: now)

        var event = incoming
        if event.sessionID == nil, event.turnID == nil,
           let active = state.activeTasksBySource[event.source.rawValue],
           now.timeIntervalSince(active.timestamp) < 5 * 60 {
            event = event.associated(sessionID: active.sessionID, turnID: active.turnID)
        }

        let exactKey = "exact|\(event.dedupeKey)"
        let coarseKey = "coarse|\(event.source.rawValue)|\(event.status.rawValue)|\(event.turnID ?? event.sessionID ?? event.projectName)"
        if let date = state.dedupeDates[exactKey], now.timeIntervalSince(date) < 10 { return nil }
        if let date = state.dedupeDates[coarseKey], now.timeIntervalSince(date) < 2.5 { return nil }

        let taskKey = "\(event.source.rawValue)|\(event.sessionID ?? "unknown-session")|\(event.turnID ?? event.projectName)"
        if let existing = state.tasks[taskKey] {
            if event.timestamp < existing.timestamp { return nil }
            if existing.status == event.status, event.status != .started { return nil }
            if existing.status.isTerminal, event.status != .started { return nil }
        }

        state.dedupeDates[exactKey] = now
        state.dedupeDates[coarseKey] = now
        state.tasks[taskKey] = TaskState(status: event.status, timestamp: event.timestamp)
        if event.status == .started || event.status == .waiting {
            state.activeTasksBySource[event.source.rawValue] = ActiveTask(
                sessionID: event.sessionID,
                turnID: event.turnID,
                timestamp: now
            )
        } else if event.status.isTerminal {
            state.activeTasksBySource.removeValue(forKey: event.source.rawValue)
        }
        persistState()
        return event
    }

    func record(_ event: TaskEvent, notificationResult: String, now: Date = Date()) {
        ensureDirectories()
        append(HistoryRecord(event: event, notificationResult: notificationResult, recordedAt: now), to: historyURL)
        compactHistory(now: now)
    }

    func recordDiagnostic(category: String, message: String, sourcePath: String? = nil, now: Date = Date()) {
        ensureDirectories()
        append(DiagnosticRecord(category: category, message: message, sourcePath: sourcePath, recordedAt: now), to: diagnosticsURL)
    }

    func clearLocalRecords() -> ClearResult {
        let fileManager = FileManager.default
        var removedFiles = 0
        for url in [historyURL, stateURL, diagnosticsDirectory] where fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.removeItem(at: url)) != nil { removedFiles += 1 }
        }
        state = PersistedState()
        return ClearResult(removedFiles: removedFiles)
    }

    private func pruneState(now: Date) {
        state.dedupeDates = state.dedupeDates.filter { now.timeIntervalSince($0.value) < Self.retentionInterval }
        state.tasks = state.tasks.filter { now.timeIntervalSince($0.value.timestamp) < Self.retentionInterval }
        state.activeTasksBySource = state.activeTasksBySource.filter { now.timeIntervalSince($0.value.timestamp) < Self.retentionInterval }
    }

    private func compactHistory(now: Date) {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let records = data.split(separator: 0x0A).compactMap { line -> HistoryRecord? in
            try? decoder.decode(HistoryRecord.self, from: Data(line))
        }.filter { $0.recordedAt >= cutoff }
        let retained = records.suffix(Self.maximumHistoryCount)
        let encoded = retained.compactMap { try? encoder.encode($0) }
        var output = Data()
        for (index, item) in encoded.enumerated() {
            if index > 0 { output.append(0x0A) }
            output.append(item)
        }
        if !output.isEmpty { output.append(0x0A) }
        try? output.write(to: historyURL, options: .atomic)
    }

    private func persistState() {
        ensureDirectories()
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
    }

    private func append<T: Encodable>(_ value: T, to url: URL) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }
}

private extension TaskStatus {
    var isTerminal: Bool {
        self == .completed || self == .interrupted || self == .failed
    }
}
