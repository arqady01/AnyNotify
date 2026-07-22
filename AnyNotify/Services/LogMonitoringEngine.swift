import Foundation

actor LogMonitoringEngine {
    static let defaultMaximumTrackedFiles = 64

    struct Availability: Sendable {
        let claude: Bool
        let codex: Bool
    }

    struct PollResult: Sendable {
        let events: [TaskEvent]
        let availability: Availability
    }

    private struct FileCursor: Sendable {
        var offset: UInt64
        var remainder = Data()
    }

    struct CachedStateCounts: Sendable {
        let cursors: Int
        let claudeParsers: Int
        let codexParsers: Int
    }

    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let maximumTrackedFiles: Int
    private var cursors: [URL: FileCursor] = [:]
    private var claudeParsers: [URL: ClaudeLogParser] = [:]
    private var codexParsers: [URL: CodexLogParser] = [:]
    private var fileAccessOrder: [URL] = []
    private var initialized = false

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumTrackedFiles: Int = LogMonitoringEngine.defaultMaximumTrackedFiles
    ) {
        precondition(maximumTrackedFiles > 0)
        self.homeDirectory = homeDirectory
        self.maximumTrackedFiles = maximumTrackedFiles
    }

    func poll() -> PollResult {
        let claudeRoot = homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let codexRoot = homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        let tuiLog = homeDirectory.appending(path: ".codex/log/codex-tui.log")

        let claudeFiles = recentJSONLFiles(in: claudeRoot, limit: 8)
        let codexFiles = recentJSONLFiles(in: codexRoot, limit: 8)
        var events: [TaskEvent] = []

        for file in claudeFiles {
            markFileAccessed(file)
            let lines = readNewLines(from: file, seedAtEnd: !initialized)
            var parser = claudeParsers[file] ?? ClaudeLogParser()
            for line in lines { events.append(contentsOf: parser.parse(line: line)) }
            claudeParsers[file] = parser
        }

        for file in codexFiles {
            markFileAccessed(file)
            let lines = readNewLines(from: file, seedAtEnd: !initialized)
            var parser = codexParsers[file] ?? CodexLogParser()
            for line in lines { events.append(contentsOf: parser.parse(line: line)) }
            codexParsers[file] = parser
        }

        if fileManager.fileExists(atPath: tuiLog.path) {
            markFileAccessed(tuiLog)
            for line in readNewLines(from: tuiLog, seedAtEnd: !initialized) {
                if let event = parseCodexErrorLog(line) { events.append(event) }
            }
        }

        trimCachedFileState()
        initialized = true
        return PollResult(
            events: events,
            availability: Availability(
                claude: fileManager.fileExists(atPath: claudeRoot.path),
                codex: fileManager.fileExists(atPath: codexRoot.path)
            )
        )
    }

    private func recentJSONLFiles(in root: URL, limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
            files.sort { $0.1 > $1.1 }
            if files.count > limit {
                files.removeLast(files.count - limit)
            }
        }
        return files.map(\.0)
    }

    func cachedStateCounts() -> CachedStateCounts {
        CachedStateCounts(
            cursors: cursors.count,
            claudeParsers: claudeParsers.count,
            codexParsers: codexParsers.count
        )
    }

    private func markFileAccessed(_ url: URL) {
        fileAccessOrder.removeAll { $0 == url }
        fileAccessOrder.append(url)
    }

    private func trimCachedFileState() {
        let excessCount = fileAccessOrder.count - maximumTrackedFiles
        guard excessCount > 0 else { return }

        let evictedFiles = fileAccessOrder.prefix(excessCount)
        fileAccessOrder.removeFirst(excessCount)
        for file in evictedFiles {
            cursors.removeValue(forKey: file)
            claudeParsers.removeValue(forKey: file)
            codexParsers.removeValue(forKey: file)
        }
    }

    private func readNewLines(from url: URL, seedAtEnd: Bool) -> [Data] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber else { return [] }
        let size = sizeNumber.uint64Value

        if cursors[url] == nil {
            cursors[url] = FileCursor(offset: seedAtEnd ? size : 0)
            if seedAtEnd { return [] }
        }

        var cursor = cursors[url] ?? FileCursor(offset: 0)
        if size < cursor.offset {
            cursor = FileCursor(offset: 0)
        }
        guard size > cursor.offset else {
            cursors[url] = cursor
            return []
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.readToEnd() ?? Data()
            cursor.offset += UInt64(data.count)
            cursor.remainder.append(data)
        } catch {
            return []
        }

        var lines = splitLines(cursor.remainder)
        cursor.remainder = lines.popLast() ?? Data()
        cursors[url] = cursor
        return lines.filter { !$0.isEmpty }
    }

    private func parseCodexErrorLog(_ data: Data) -> TaskEvent? {
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        let lower = line.lowercased()
        let ignored = [
            "stream disconnected - retrying sampling request",
            "retrying sampling request",
            "failed to sync plugins"
        ]
        guard !ignored.contains(where: lower.contains) else { return nil }

        let terminalErrors = [
            "turn error:", "stream disconnected before completion", "api error:",
            "error sending request for url", "please run /login", "authentication failed",
            "request failed", "connection failed", "network error",
            "timeout waiting for child process to exit"
        ]
        guard terminalErrors.contains(where: lower.contains) else { return nil }
        let summary = line.components(separatedBy: "] ").last ?? line
        return TaskEvent(source: .codex, status: .failed, summary: summary.shortenedForNotification)
    }

    private func splitLines(_ data: Data) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                result.append(data[start..<index])
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        result.append(data[start..<data.endIndex])
        return result
    }
}
