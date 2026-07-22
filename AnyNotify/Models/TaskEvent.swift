import Foundation

enum TaskSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "c.circle.fill"
        case .codex: "terminal.fill"
        }
    }
}

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case started
    case completed
    case waiting
    case interrupted
    case failed

    var displayName: String {
        switch self {
        case .started: "已开始"
        case .completed: "已完成"
        case .waiting: "等待输入"
        case .interrupted: "已中断"
        case .failed: "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .started: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .waiting: "questionmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct TaskEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let source: TaskSource
    let status: TaskStatus
    let sessionID: String?
    let turnID: String?
    let workingDirectory: String?
    let summary: String
    let timestamp: Date

    nonisolated init(
        id: UUID = UUID(),
        source: TaskSource,
        status: TaskStatus,
        sessionID: String? = nil,
        turnID: String? = nil,
        workingDirectory: String? = nil,
        summary: String = "",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.status = status
        self.sessionID = sessionID
        self.turnID = turnID
        self.workingDirectory = workingDirectory
        self.summary = summary
        self.timestamp = timestamp
    }

    nonisolated var projectName: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return "" }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    nonisolated var notificationTitle: String {
        "\(source.displayName) · \(status.displayName)"
    }

    nonisolated var notificationBody: String {
        notificationBody(includeDetails: false)
    }

    nonisolated func notificationBody(includeDetails: Bool) -> String {
        guard includeDetails else { return "任务状态已更新" }
        let parts = [projectName.redactedForNotification, summary.redactedForNotification]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "任务状态已更新" : parts.joined(separator: " — ")
    }

    nonisolated var dedupeKey: String {
        let stableTurn = turnID ?? sessionID ?? projectName
        return "\(source.rawValue)|\(status.rawValue)|\(stableTurn)|\(summary.normalizedForDedupe)"
    }

    nonisolated func associated(sessionID: String?, turnID: String?) -> TaskEvent {
        TaskEvent(
            id: id,
            source: source,
            status: status,
            sessionID: self.sessionID ?? sessionID,
            turnID: self.turnID ?? turnID,
            workingDirectory: workingDirectory,
            summary: summary,
            timestamp: timestamp
        )
    }
}

extension String {
    nonisolated var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var firstUsefulLine: String {
        split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmed }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    nonisolated var shortenedForNotification: String {
        let line = firstUsefulLine
        guard line.count > 160 else { return line }
        return String(line.prefix(157)) + "…"
    }

    nonisolated fileprivate var normalizedForDedupe: String {
        lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(200)
            .description
    }

    nonisolated var redactedForNotification: String {
        var redacted = self
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(?:api[_-]?key|access[_-]?token|auth(?:orization)?|password|passwd|secret|token)\s*[:=]\s*['\"]?[^\s,'\"]+"#,
            #"\bsk-[A-Za-z0-9_-]{12,}"#,
            #"\b(?:ghp|gho|ghs|ghu|ghr|github_pat)_[A-Za-z0-9_]{12,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"\b(?:xoxb|xoxp|xoxa|xoxr)-[A-Za-z0-9-]{10,}"#,
            #"-----BEGIN [^-]+ PRIVATE KEY-----"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[已隐藏]",
                options: .regularExpression
            )
        }
        return redacted.firstUsefulLine.shortenedForNotification
    }
}
